import Foundation

@main
enum LLMProviderTests {
    static func main() throws {
        testJSONValue()
        try testEncodeBlocks()
        try testRequestBody()
        try testSSEParser()
        try testParseResponse()
        testChatStore()
        print("LLM provider: all cases passed")
    }

    // MARK: - JSONValue

    static func testJSONValue() {
        let any: [String: Any] = ["s": "x", "n": 3.5, "b": true, "nil": NSNull(), "a": [1, 2]]
        guard case .object(let obj) = JSONValue(any: any) else { preconditionFailure("object expected") }
        precondition(obj["s"] == .string("x"))
        precondition(obj["n"] == .number(3.5))
        precondition(obj["b"] == .bool(true))
        precondition(obj["nil"] == .null)
        precondition(obj["a"] == .array([.number(1), .number(2)]))

        precondition(JSONValue.string("a").anyValue as? String == "a")
        precondition(JSONValue.number(1).anyValue as? Double == 1.0)
        precondition((JSONValue.bool(false).anyValue as? Bool) == false)
        precondition(JSONValue.null.anyValue is NSNull)
        precondition(JSONValue.string("hi").stringValue == "hi")
        precondition(JSONValue.number(1).stringValue == nil)

        // Subscript
        let schema = JSONValue.object(["cmd": .string("rm")])
        precondition(schema["cmd"] == .string("rm"))
        precondition(schema["missing"] == nil)
        precondition(JSONValue.string("x")["cmd"] == nil)
    }

    // MARK: - Wire encoding

    static func testEncodeBlocks() throws {
        let blocks: [LLMContentBlock] = [
            .text("hello"),
            .image(mediaType: "image/png", base64: "QUJD"),
            .document(mediaType: "application/pdf", base64: "JVBERi0"),
            .toolUse(id: "t1", name: "lookup", input: .object(["q": .string("paris")])),
            .toolResult(id: "t1", content: "done", isError: true),
        ]
        let wire = AnthropicProvider.encodeBlocks(blocks)
        precondition(wire.count == 5)

        precondition(wire[0]["type"] as? String == "text")
        precondition(wire[0]["text"] as? String == "hello")

        precondition(wire[1]["type"] as? String == "image")
        let src = wire[1]["source"] as? [String: String]
        precondition(src?["type"] == "base64")
        precondition(src?["media_type"] == "image/png")
        precondition(src?["data"] == "QUJD")

        precondition(wire[2]["type"] as? String == "document")

        precondition(wire[3]["type"] as? String == "tool_use")
        precondition(wire[3]["id"] as? String == "t1")
        precondition(wire[3]["name"] as? String == "lookup")
        let input = wire[3]["input"] as? [String: Any]
        precondition(input?["q"] as? String == "paris")

        precondition(wire[4]["type"] as? String == "tool_result")
        precondition(wire[4]["tool_use_id"] as? String == "t1")
        precondition(wire[4]["is_error"] as? Bool == true)

        // Response text concatenates every text block
        let resp = LLMResponse(
            assistantMessage: LLMMessage(role: .assistant, content: [.text("A"), .text("B")]),
            stopReason: .endTurn
        )
        precondition(resp.text == "AB")
    }

    // MARK: - Request body

    static func testRequestBody() throws {
        let req = LLMRequest(
            model: "claude-test",
            system: "sys",
            messages: [
                LLMMessage(role: .user, content: [.text("hi")]),
                LLMMessage(role: .assistant, content: [.text("yo")]),
            ],
            maxTokens: 123,
            temperature: 0.5,
            enableWebSearch: true
        )
        let body = AnthropicProvider.requestBody(req, stream: true)
        precondition(body["model"] as? String == "claude-test")
        precondition(body["max_tokens"] as? Int == 123)
        precondition(body["stream"] as? Bool == true)
        precondition(body["system"] as? String == "sys")
        precondition(body["temperature"] as? Double == 0.5)

        let msgs = try unwrap(body["messages"] as? [[String: Any]])
        precondition(msgs.count == 2)
        precondition(msgs[0]["role"] as? String == "user")
        precondition(msgs[1]["role"] as? String == "assistant")
        let content = try unwrap(msgs[0]["content"] as? [[String: Any]])
        precondition(content[0]["text"] as? String == "hi")

        // Web search injected as a server tool
        let tools = try unwrap(body["tools"] as? [[String: Any]])
        precondition(tools.contains { $0["type"] as? String == "web_search_20250305" })
        precondition(tools.contains { $0["name"] as? String == "web_search" })

        // Default request: no temperature, no web search → no tools key
        let plain = AnthropicProvider.requestBody(
            LLMRequest(model: "m", system: "s", messages: []), stream: false)
        precondition(plain["stream"] as? Bool == false)
        precondition(plain["tools"] == nil)
        precondition(plain["temperature"] == nil)

        // Explicit client tools ride along next to web search
        let withTools = AnthropicProvider.requestBody(
            LLMRequest(model: "m", system: "s", messages: [],
                       tools: [LLMToolDef(name: "run", description: "d",
                                          inputSchema: .object(["cmd": .string("s")]))],
                       enableWebSearch: true),
            stream: false)
        let wireTools = try unwrap(withTools["tools"] as? [[String: Any]])
        precondition(wireTools.count == 2)
        precondition(wireTools[0]["name"] as? String == "run")
        let schema = wireTools[0]["input_schema"] as? [String: Any]
        precondition(schema?["cmd"] as? String == "s")
    }

    // MARK: - SSE parser

    static func testSSEParser() throws {
        var parser = AnthropicProvider.SSEParser()

        let ignored1 = try parser.feed("event: message_start")
        let ignored2 = try parser.feed("data: ")
        let ignored3 = try parser.feed("")
        precondition(ignored1.isEmpty && ignored2.isEmpty && ignored3.isEmpty)

        let start = try parser.feed(#"data: {"type":"message_start","message":{"usage":{"input_tokens":11}}}"#)
        precondition(start.isEmpty)

        let d1 = try parser.feed(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}"#)
        precondition(d1 == [.textDelta("Hel")])
        let d2 = try parser.feed(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}"#)
        precondition(d2 == [.textDelta("lo")])

        let mid = try parser.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#)
        precondition(mid.isEmpty)

        let stop = try parser.feed(#"data: {"type":"message_stop"}"#)
        precondition(stop.count == 1)
        let stopEvent = try unwrap(stop.first)
        guard case .completed(let final) = stopEvent else {
            preconditionFailure("completed expected")
        }
        precondition(final.text == "Hello")
        precondition(final.stopReason == .endTurn)
        precondition(final.usage?.inputTokens == 11)
        precondition(final.usage?.outputTokens == 7)

        // After message_stop nothing more is produced
        let late = try parser.feed(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"!"}}"#)
        precondition(late.isEmpty)
        precondition(parser.finish() == nil)

        // Connection closed without message_stop → flush
        var partial = AnthropicProvider.SSEParser()
        _ = try partial.feed(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#)
        let flushed = partial.finish()
        precondition(flushed?.text == "Hi")
        precondition(flushed?.stopReason == .unknown)

        // Fresh parser with no data at all still yields an (empty) response
        var empty = AnthropicProvider.SSEParser()
        let emptyResp = empty.finish()
        precondition(emptyResp != nil)
        precondition(emptyResp?.text.isEmpty == true)

        // error event throws LLMError
        var failing = AnthropicProvider.SSEParser()
        do {
            _ = try failing.feed(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Busy."}}"#)
            preconditionFailure("expected LLMError")
        } catch let err as LLMError {
            precondition(err.message == "Busy.")
        }
    }

    // MARK: - Non-streaming response parsing

    static func testParseResponse() throws {
        let json = """
        {"id":"msg_1","type":"message","role":"assistant","model":"m",
         "content":[{"type":"text","text":"Bonjour"},
                    {"type":"server_tool_use","id":"su_1","name":"web_search","input":{"query":"x"}},
                    {"type":"tool_use","id":"tu_1","name":"lookup","input":{"q":"paris"}}],
         "stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":20}}
        """
        let resp = try AnthropicProvider.parseResponse(Data(json.utf8), model: "m")
        precondition(resp.text == "Bonjour")
        precondition(resp.stopReason == .endTurn)
        precondition(resp.usage?.inputTokens == 10)
        precondition(resp.usage?.outputTokens == 20)
        // text + server_tool_use (web search) + client tool_use
        precondition(resp.assistantMessage.content.count == 3)
        guard case .toolUse(let suId, let suName, _) = resp.assistantMessage.content[1] else {
            preconditionFailure("server tool block expected")
        }
        precondition(suId == "su_1")
        precondition(suName == "web_search")
        guard case .toolUse(let id, let name, let input) = resp.assistantMessage.content[2] else {
            preconditionFailure("toolUse block expected")
        }
        precondition(id == "tu_1")
        precondition(name == "lookup")
        precondition(input["q"] == .string("paris"))

        // Malformed payload
        do {
            _ = try AnthropicProvider.parseResponse(Data("{}".utf8), model: "m")
            preconditionFailure("expected throw")
        } catch is LLMError {
            // expected
        }

        // Empty content
        do {
            _ = try AnthropicProvider.parseResponse(
                Data(#"{"content":[],"stop_reason":"end_turn"}"#.utf8), model: "m")
            preconditionFailure("expected throw")
        } catch let err as LLMError {
            precondition(err.message == "No response text.")
        }

        // HTTP error mapping
        let authErr = AnthropicProvider.apiError(
            Data(#"{"type":"error","error":{"type":"authentication_error","message":"bad key"}}"#.utf8),
            statusCode: 401, model: "m")
        precondition(authErr.message == "Invalid Anthropic API key. Check Settings.")

        let missing = AnthropicProvider.apiError(
            Data(#"{"type":"error","error":{"type":"not_found_error","message":"nope"}}"#.utf8),
            statusCode: 404, model: "claude-ghost")
        precondition(missing.message.hasPrefix("Model not found: claude-ghost."))

        let rate = AnthropicProvider.apiError(
            Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8),
            statusCode: 429, model: "m")
        precondition(rate.message.hasPrefix("Rate limited by Anthropic"))

        let generic = AnthropicProvider.apiError(
            Data(#"{"type":"error","error":{"type":"api_error","message":"Boom."}}"#.utf8),
            statusCode: 500, model: "m")
        precondition(generic.message == "Boom.")
    }

    // MARK: - ChatStore

    static func testChatStore() {
        let store = ChatStore()
        precondition(store.isEmpty)
        precondition(store.count == 0)

        store.appendUser([.text("q1")])
        store.appendAssistant(text: "a1")
        precondition(store.count == 2)
        precondition(store.all[0].role == .user)
        precondition(store.all[1].role == .assistant)
        precondition(store.all[0].content.count == 1)
        precondition(store.all[0].content[0].text == "q1")

        // Multi-turn continues
        store.appendUser([.text("q2")])
        precondition(store.count == 3)

        // Rollback drops only the last message
        store.rollbackLast()
        precondition(store.count == 2)

        // Blank assistant text is ignored
        store.appendAssistant(text: "   \n")
        precondition(store.count == 2)

        // Rollback on empty is a no-op
        store.clear()
        precondition(store.isEmpty)
        store.rollbackLast()
        precondition(store.isEmpty)
    }

    // MARK: - Helpers

    /// `try` can't appear inside `precondition` (non-throwing autoclosure) — unwrap here instead.
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw LLMError("Expected value, got nil.") }
        return value
    }
}
