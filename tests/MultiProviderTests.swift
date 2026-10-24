import Foundation

@main
enum MultiProviderTests {
    static func main() throws {
        try testOpenAIRequestBody()
        try testOpenAIEncodeMessages()
        try testOpenAISSEParser()
        try testOpenAIParseResponse()
        try testOpenAIModelsFilter()
        try testGeminiRequestBody()
        try testGeminiSSEParser()
        try testGeminiParseResponse()
        try testGeminiModelsFilter()
        try testRegistryAndFallbacks()
        print("Multi-provider: all cases passed")
    }

    // MARK: - OpenAI request body

    static func testOpenAIRequestBody() throws {
        let req = LLMRequest(
            model: "gpt-6.1-sol",
            system: "Be JARVIS.",
            messages: [
                LLMMessage(role: .user, content: [.text("hi")]),
                LLMMessage(role: .assistant, content: [.text("yo")]),
            ],
            maxTokens: 777,
            temperature: 0.2,
            enableWebSearch: true
        )
        let body = OpenAIProvider.requestBody(req, stream: true, enableWebSearch: true)
        precondition(body["model"] as? String == "gpt-6.1-sol")
        precondition(body["max_completion_tokens"] as? Int == 777)
        precondition(body["stream"] as? Bool == true)
        precondition(body["temperature"] as? Double == 0.2)

        let opts = body["stream_options"] as? [String: Any]
        precondition(opts?["include_usage"] as? Bool == true)
        precondition(body["web_search_options"] != nil)

        let msgs = try unwrap(body["messages"] as? [[String: Any]])
        precondition(msgs.count == 3)
        precondition(msgs[0]["role"] as? String == "system")
        precondition(msgs[0]["content"] as? String == "Be JARVIS.")
        precondition(msgs[1]["role"] as? String == "user")
        precondition(msgs[2]["role"] as? String == "assistant")

        // No web search, no temperature by default
        let plain = OpenAIProvider.requestBody(
            LLMRequest(model: "m", system: "s", messages: []), stream: false, enableWebSearch: false)
        precondition(plain["web_search_options"] == nil)
        precondition(plain["temperature"] == nil)
        precondition(plain["stream_options"] == nil)
        precondition(plain["stream"] == nil) // only set when streaming

        // Client tools ride along
        let withTools = OpenAIProvider.requestBody(
            LLMRequest(model: "m", system: "s", messages: [],
                       tools: [LLMToolDef(name: "run", description: "d",
                                          inputSchema: .object(["cmd": .string("s")]))]),
            stream: false, enableWebSearch: false)
        let wireTools = try unwrap(withTools["tools"] as? [[String: Any]])
        precondition(wireTools.count == 1)
        precondition(wireTools[0]["type"] as? String == "function")
        precondition(wireTools[0]["function"] != nil)
    }

    // MARK: - OpenAI message encoding

    static func testOpenAIEncodeMessages() throws {
        // Tool results precede the user text; assistant tool_use becomes tool_calls.
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: [
                .toolResult(id: "t1", content: "done", isError: false),
                .text("what next?"),
            ]),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "t1", name: "lookup", input: .object(["q": .string("paris")])),
            ]),
        ]
        let wire = OpenAIProvider.encodeMessages(messages)
        precondition(wire.count == 3)

        precondition(wire[0]["role"] as? String == "tool")
        precondition(wire[0]["tool_call_id"] as? String == "t1")
        precondition(wire[0]["content"] as? String == "done")

        precondition(wire[1]["role"] as? String == "user")
        precondition(wire[1]["content"] as? String == "what next?")

        precondition(wire[2]["role"] as? String == "assistant")
        precondition(wire[2]["content"] is NSNull) // empty text + tool_calls
        let calls = try unwrap(wire[2]["tool_calls"] as? [[String: Any]])
        precondition(calls.count == 1)
        precondition(calls[0]["id"] as? String == "t1")
        precondition(calls[0]["type"] as? String == "function")
        let fn = try unwrap(calls[0]["function"] as? [String: Any])
        precondition(fn["name"] as? String == "lookup")
        precondition(fn["arguments"] as? String == #"{"q":"paris"}"#)

        // Image part → data URL
        let img = OpenAIProvider.encodeMessages([
            LLMMessage(role: .user, content: [.image(mediaType: "image/png", base64: "QUJD")]),
        ])
        precondition(img.count == 1)
        let imgParts = try unwrap(img[0]["content"] as? [[String: Any]])
        precondition(imgParts.count == 1)
        precondition(imgParts[0]["type"] as? String == "image_url")
        precondition((imgParts[0]["image_url"] as? [String: Any])?["url"] as? String
                     == "data:image/png;base64,QUJD")
    }

    // MARK: - OpenAI SSE parser

    static func testOpenAISSEParser() throws {
        var parser = OpenAIProvider.SSEParser()

        let e0 = try parser.feed("")
        precondition(e0.isEmpty)
        let e1 = try parser.feed("event: message")
        precondition(e1.isEmpty)
        let e2 = try parser.feed(#"data: {"id":"x","choices":[]}"#)
        precondition(e2.isEmpty)

        let d1 = try parser.feed(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        precondition(d1 == [.textDelta("Hel")])
        let d2 = try parser.feed(#"data: {"choices":[{"delta":{"content":"lo"}}]}"#)
        precondition(d2 == [.textDelta("lo")])

        // finish_reason recorded, no event yet
        let fin = try parser.feed(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        precondition(fin.isEmpty)

        // usage-only chunk
        let usage = try parser.feed(#"data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9}}"#)
        precondition(usage.isEmpty)

        // [DONE] → one completed
        let done = try parser.feed("data: [DONE]")
        precondition(done.count == 1)
        guard case .completed(let final) = try unwrap(done.first) else {
            preconditionFailure("completed expected")
        }
        precondition(final.text == "Hello")
        precondition(final.stopReason == .endTurn)
        precondition(final.usage?.inputTokens == 5)
        precondition(final.usage?.outputTokens == 9)
        precondition(parser.finish() == nil)

        // Tool-call delta accumulation
        var toolParser = OpenAIProvider.SSEParser()
        _ = try toolParser.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":""}}]}}]}"#)
        _ = try toolParser.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":"}}]}}]}"#)
        _ = try toolParser.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"paris\"}"}}]}}]}"#)
        _ = try toolParser.feed(#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        let toolDone = try toolParser.feed("data: [DONE]")
        guard case .completed(let toolResp) = try unwrap(toolDone.first) else {
            preconditionFailure("completed expected")
        }
        precondition(toolResp.stopReason == .toolUse)
        let firstBlock = try unwrap(toolResp.assistantMessage.content.first)
        guard case .toolUse(let id, let name, let input) = firstBlock else {
            preconditionFailure("toolUse expected")
        }
        precondition(id == "call_1")
        precondition(name == "lookup")
        precondition(input["q"] == .string("paris"))

        // Connection closed without [DONE] → flush
        var partial = OpenAIProvider.SSEParser()
        _ = try partial.feed(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#)
        let flushed = partial.finish()
        precondition(flushed?.text == "Hi")

        // Error event throws LLMError
        var failing = OpenAIProvider.SSEParser()
        do {
            _ = try failing.feed(#"data: {"error":{"message":"rate limited."}}"#)
            preconditionFailure("expected LLMError")
        } catch let err as LLMError {
            precondition(err.message == "rate limited.")
        }
    }

    // MARK: - OpenAI non-streaming response

    static func testOpenAIParseResponse() throws {
        let json = """
        {"id":"c1","object":"chat.completion",
         "choices":[{"index":0,"message":{"role":"assistant","content":"Salut"},
                     "finish_reason":"stop"}],
         "usage":{"prompt_tokens":11,"completion_tokens":22}}
        """
        let resp = try OpenAIProvider.parseResponse(Data(json.utf8), model: "m")
        precondition(resp.text == "Salut")
        precondition(resp.stopReason == .endTurn)
        precondition(resp.usage?.inputTokens == 11)
        precondition(resp.usage?.outputTokens == 22)

        // Tool call response
        let toolJSON = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"call_9","type":"function",
                         "function":{"name":"run","arguments":"{\\"cmd\\":\\"ls\\"}"}}]},
          "finish_reason":"tool_calls"}]}
        """
        let toolResp = try OpenAIProvider.parseResponse(Data(toolJSON.utf8), model: "m")
        precondition(toolResp.stopReason == .toolUse)
        let firstBlock = try unwrap(toolResp.assistantMessage.content.first)
        guard case .toolUse(let id, let name, let input) = firstBlock else {
            preconditionFailure("toolUse expected")
        }
        precondition(id == "call_9")
        precondition(name == "run")
        precondition(input["cmd"] == .string("ls"))

        // Empty content throws
        do {
            _ = try OpenAIProvider.parseResponse(Data(#"{"choices":[]}"#.utf8), model: "m")
            preconditionFailure("expected throw")
        } catch is LLMError {}

        let lengthJSON = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":"cut"},
                     "finish_reason":"length"}]}
        """
        let lengthResp = try OpenAIProvider.parseResponse(Data(lengthJSON.utf8), model: "m")
        precondition(lengthResp.stopReason == .maxTokens)

        // HTTP error mapping
        precondition(OpenAIProvider.apiError(
            Data(#"{"error":{"message":"bad key"}}"#.utf8), statusCode: 401, model: "m"
        ).message == "Invalid OpenAI API key. Check Settings.")
        precondition(OpenAIProvider.apiError(
            Data(#"{"error":{"message":"slow"}}"#.utf8), statusCode: 429, model: "m"
        ).message.hasPrefix("Rate limited by OpenAI"))
        precondition(OpenAIProvider.apiError(
            Data(#"{"error":{"message":"no model"}}"#.utf8), statusCode: 404, model: "gpt-ghost"
        ).message.hasPrefix("Model not found: gpt-ghost."))

        // Web-search retry detection
        precondition(OpenAIProvider.mentionsWebSearch(
            Data(#"{"error":{"message":"web_search tool is not allowed"}}"#.utf8)))
        precondition(!OpenAIProvider.mentionsWebSearch(Data(#"{"error":{"message":"timeout"}}"#.utf8)))

        // Argument parsing fallback
        precondition(OpenAIProvider.parseArguments(#"{"a":1}"#)["a"] == .number(1))
        precondition(OpenAIProvider.parseArguments("{not json") == .object([:]))
        precondition(OpenAIProvider.parseArguments(nil) == .object([:]))
    }

    // MARK: - OpenAI model list filter

    static func testOpenAIModelsFilter() throws {
        let json = """
        {"object":"list","data":[
          {"id":"gpt-6.1-sol","created":6},
          {"id":"text-embedding-3-small","created":5},
          {"id":"gpt-6.1-mini","created":4},
          {"id":"o4-mini","created":3},
          {"id":"gpt-6-sol-search-preview","created":2},
          {"id":"whisper-1","created":1}
        ]}
        """
        let list = OpenAIProvider.parseModelList(Data(json.utf8))
        precondition(list.map { $0.id } == ["gpt-6.1-sol", "gpt-6.1-mini", "o4-mini"])
        precondition(list.map { $0.label } == ["gpt-6.1-sol", "gpt-6.1-mini", "o4-mini"])
    }

    // MARK: - Gemini request body

    static func testGeminiRequestBody() throws {
        let req = LLMRequest(
            model: "gemini-3.6-flash",
            system: "Be JARVIS.",
            messages: [
                LLMMessage(role: .user, content: [.text("hi")]),
                LLMMessage(role: .assistant, content: [
                    .toolUse(id: "t1", name: "lookup", input: .object(["q": .string("paris")])),
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(id: "t1", content: "done", isError: true),
                ]),
            ],
            maxTokens: 500,
            enableWebSearch: false
        )
        let body = GeminiProvider.requestBody(req, enableGoogleSearch: false)

        let sys = body["systemInstruction"] as? [String: Any]
        let sysParts = try unwrap(sys?["parts"] as? [[String: Any]])
        precondition(sysParts[0]["text"] as? String == "Be JARVIS.")

        let contents = try unwrap(body["contents"] as? [[String: Any]])
        precondition(contents.count == 3)
        precondition(contents[0]["role"] as? String == "user")
        precondition(contents[1]["role"] as? String == "model")
        precondition(contents[2]["role"] as? String == "user")

        // functionCall on the model turn
        let modelParts = try unwrap(contents[1]["parts"] as? [[String: Any]])
        let call = try unwrap(modelParts[0]["functionCall"] as? [String: Any])
        precondition(call["name"] as? String == "lookup")
        let args = try unwrap(call["args"] as? [String: Any])
        precondition(args["q"] as? String == "paris")

        // functionResponse picks the name from the prior toolUse by id
        let userParts = try unwrap(contents[2]["parts"] as? [[String: Any]])
        let resp = try unwrap(userParts[0]["functionResponse"] as? [String: Any])
        precondition(resp["name"] as? String == "lookup")
        let inner = try unwrap(resp["response"] as? [String: Any])
        precondition(inner["content"] as? String == "done")
        precondition(inner["error"] as? Bool == true)

        let gen = try unwrap(body["generationConfig"] as? [String: Any])
        precondition(gen["maxOutputTokens"] as? Int == 500)

        // functionDeclarations XOR googleSearch
        precondition(body["tools"] == nil)
        let withTools = GeminiProvider.requestBody(
            LLMRequest(model: "m", system: "s", messages: [],
                       tools: [LLMToolDef(name: "run", description: "d",
                                          inputSchema: .object(["cmd": .string("s")]))]),
            enableGoogleSearch: false)
        let tools = try unwrap(withTools["tools"] as? [[String: Any]])
        let decls = try unwrap(tools[0]["functionDeclarations"] as? [[String: Any]])
        precondition(decls.count == 1)
        precondition(decls[0]["name"] as? String == "run")

        let searched = GeminiProvider.requestBody(
            LLMRequest(model: "m", system: "s", messages: []), enableGoogleSearch: true)
        precondition((searched["tools"] as? [[String: Any]])?.first?["googleSearch"] != nil)

        // No system → no systemInstruction
        let noSys = GeminiProvider.requestBody(
            LLMRequest(model: "m", system: "", messages: []), enableGoogleSearch: false)
        precondition(noSys["systemInstruction"] == nil)
    }

    // MARK: - Gemini SSE parser

    static func testGeminiSSEParser() throws {
        var parser = GeminiProvider.SSEParser()

        let g0 = try parser.feed("")
        precondition(g0.isEmpty)
        let g1 = try parser.feed("data: ")
        precondition(g1.isEmpty)

        let d1 = try parser.feed(#"data: {"candidates":[{"content":{"parts":[{"text":"Sal"}]}}]}"#)
        precondition(d1 == [.textDelta("Sal")])
        let d2 = try parser.feed(#"data: {"candidates":[{"content":{"parts":[{"text":"ut"}]}}]}"#)
        precondition(d2 == [.textDelta("ut")])

        // finishReason recorded, no event
        let fin = try parser.feed(#"data: {"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":8}}"#)
        precondition(fin.isEmpty)

        let done = try parser.feed("data: [DONE]")
        precondition(done.count == 1)
        guard case .completed(let final) = try unwrap(done.first) else {
            preconditionFailure("completed expected")
        }
        precondition(final.text == "Salut")
        precondition(final.stopReason == .endTurn)
        precondition(final.usage?.inputTokens == 4)
        precondition(final.usage?.outputTokens == 8)
        precondition(parser.finish() == nil)

        // functionCall part completes with stopReason toolUse
        var toolParser = GeminiProvider.SSEParser()
        _ = try toolParser.feed(#"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"run","args":{"cmd":"ls"}}}]},"finishReason":"STOP"}]}"#)
        let toolDone = try toolParser.feed("data: [DONE]")
        guard case .completed(let toolResp) = try unwrap(toolDone.first) else {
            preconditionFailure("completed expected")
        }
        precondition(toolResp.stopReason == .toolUse)
        let firstBlock = try unwrap(toolResp.assistantMessage.content.first)
        guard case .toolUse(_, let name, let input) = firstBlock else {
            preconditionFailure("functionCall expected as toolUse")
        }
        precondition(name == "run")
        precondition(input["cmd"] == .string("ls"))

        // Connection closed → flush
        var partial = GeminiProvider.SSEParser()
        _ = try partial.feed(#"data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#)
        precondition(partial.finish()?.text == "Hi")

        // error event throws
        var failing = GeminiProvider.SSEParser()
        do {
            _ = try failing.feed(#"data: {"error":{"message":"quota exceeded."}}"#)
            preconditionFailure("expected LLMError")
        } catch let err as LLMError {
            precondition(err.message == "quota exceeded.")
        }
    }

    // MARK: - Gemini non-streaming response

    static func testGeminiParseResponse() throws {
        let json = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Bonjour"}]},
                        "finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":14}}
        """
        let resp = try GeminiProvider.parseResponse(Data(json.utf8))
        precondition(resp.text == "Bonjour")
        precondition(resp.stopReason == .endTurn)
        precondition(resp.usage?.inputTokens == 7)
        precondition(resp.usage?.outputTokens == 14)

        let cutResp = try GeminiProvider.parseResponse(Data("""
        {"candidates":[{"content":{"parts":[{"text":"cut"}]},
                        "finishReason":"MAX_TOKENS"}]}
        """.utf8))
        precondition(cutResp.stopReason == .maxTokens)

        do {
            _ = try GeminiProvider.parseResponse(Data("{}".utf8))
            preconditionFailure("expected throw")
        } catch let err as LLMError {
            precondition(err.message == "No response text.")
        }

        precondition(GeminiProvider.apiError(
            Data(#"{"error":{"message":"API key not valid."}}"#.utf8), statusCode: 401, model: "m"
        ).message == "Invalid Google API key. Check Settings.")
        precondition(GeminiProvider.apiError(
            Data(#"{"error":{"message":"slow down"}}"#.utf8), statusCode: 429, model: "m"
        ).message.hasPrefix("Rate limited by Gemini"))
        precondition(GeminiProvider.apiError(
            Data(#"{"error":{"message":"nope"}}"#.utf8), statusCode: 404, model: "gemini-ghost"
        ).message.hasPrefix("Model not found: gemini-ghost."))

        precondition(GeminiProvider.mentionsSearch(
            Data(#"{"error":{"message":"Google Search grounding is not enabled"}}"#.utf8)))
        precondition(!GeminiProvider.mentionsSearch(Data(#"{"error":{"message":"timeout"}}"#.utf8)))
    }

    // MARK: - Gemini model list filter

    static func testGeminiModelsFilter() throws {
        let json = """
        {"models":[
          {"name":"models/gemini-3.6-flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},
          {"name":"models/aqa","supportedGenerationMethods":["generateContent"]}
        ]}
        """
        let geminiList = GeminiProvider.parseModelList(Data(json.utf8))
        precondition(geminiList.map { $0.id } == ["gemini-3.6-flash", "aqa"])
    }

    // MARK: - Registry wiring

    static func testRegistryAndFallbacks() throws {
        let registry = ProviderRegistry.shared
        precondition(registry.provider(id: "anthropic") != nil)
        precondition(registry.provider(id: "openai") != nil)
        precondition(registry.provider(id: "gemini") != nil)

        // The first registered provider (Anthropic) keeps its position.
        precondition(registry.available.first?.id == "anthropic")

        let active = registry.activeProvider
        precondition(registry.provider(id: active.id) != nil)

        for id in ["anthropic", "openai", "gemini"] {
            let provider = try unwrap(registry.provider(id: id))
            precondition(!provider.defaultModel.isEmpty)
            precondition(!provider.fallbackModels.isEmpty)
            precondition(provider.fallbackModels.contains { $0.id == provider.defaultModel },
                         "\(id) fallbacks must include its default model")
        }

        // Unknown id → nil (Settings guards on this)
        precondition(registry.provider(id: "does-not-exist") == nil)
    }

    // MARK: - Helpers

    /// `try` can't appear inside `precondition` (non-throwing autoclosure) — unwrap here instead.
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw LLMError("Expected value, got nil.") }
        return value
    }
}
