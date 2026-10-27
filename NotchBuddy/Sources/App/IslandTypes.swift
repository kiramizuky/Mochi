import Foundation

// MARK: - Island Mode

enum IslandMode: String, CaseIterable {
    case hidden, peek, compact, expanded
}

// MARK: - Island View

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case confused, upload, uploading, choose, mail, prompt
    case searching, result, note, settings, greeting, media
}

// MARK: - Bot State

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}

// MARK: - Bot Emote

enum BotEmote: String, CaseIterable {
    case love, surprised, proud, wink, yawn, happy, annoyed
}

// MARK: - Approval info (pending PermissionRequest from Claude Code or agent tool)

enum ApprovalSource: Sendable, Equatable {
    case hook
    case agent
}

struct ApprovalInfo: Sendable {
    var sessionId: String
    var tool: String
    var command: String
    var source: ApprovalSource = .hook
}

// MARK: - Pill badge (shown on pill edge when non-focused task has an alert)

enum PillBadge { case approval, finished, error }

// MARK: - Agent Task

struct AgentTask: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String          // hex
    var state: BotState
    var stepIndex: Int = 0
    var steps: [String]
    var source: AgentSource
    var isIntegration: Bool = false  // true for persistent integration pills
    var emote: BotEmote? = nil
    var miniEye: EyeShape? = nil
    var pillBadge: PillBadge? = nil  // alert badge shown on pill when not focused
    var sessionCwd: String?  = nil  // last known working directory (Claude Code sessions)
}

enum AgentSource: Equatable {
    case claudeCode
    case n8n
    case app
}

// MARK: - View dimensions (from VIEWS in prototype)

struct ViewLayout {
    let height: CGFloat
    let botX: CGFloat
    let botY: CGFloat?         // nil = auto-centered
    let botDiameter: CGFloat
    let agentMode: AgentLayoutMode
}

enum AgentLayoutMode {
    case none, grid, pills, column
}

// MARK: - Constants (from NW, NH, EW in prototype)

enum IslandConst {
    static let notchWidth: CGFloat  = IslandScreenGeometry.fallbackNotchWidth
    static let notchHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 640
    static let earRadius: CGFloat   = 14
    static let roundedCorner: CGFloat = 14    // hidden/peek/compact
    static let expandedCorner: CGFloat = 22

    static let viewLayouts: [IslandView: ViewLayout] = [
        // Home is the reference: height 150
        .overview:  ViewLayout(height: 160, botX: 68,  botY: nil, botDiameter: 58, agentMode: .pills),
        // All non-chat views match home height (150) — law
        .empty:     ViewLayout(height: 160, botX: 70,  botY: nil, botDiameter: 62, agentMode: .none),
        .approval:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .question:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .error:     ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .finished:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .confused:  ViewLayout(height: 160, botX: 76,  botY: nil, botDiameter: 66, agentMode: .column),
        .upload:    ViewLayout(height: 176, botX: 140, botY: 104, botDiameter: 62, agentMode: .column),
        .uploading: ViewLayout(height: 176, botX: 46,  botY: 118, botDiameter: 20, agentMode: .none),
        .choose:    ViewLayout(height: 176, botX: 60,  botY: 101, botDiameter: 52, agentMode: .column),
        .mail:      ViewLayout(height: 240, botX: 56,  botY: nil, botDiameter: 46, agentMode: .column),
        .prompt:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .searching: ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .result:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .note:      ViewLayout(height: 160, botX: 60,  botY: nil, botDiameter: 50, agentMode: .column),
        .settings:  ViewLayout(height: 185, botX: 54,  botY: nil, botDiameter: 46, agentMode: .none),
        .media:     ViewLayout(height: 195, botX: 54,  botY: nil, botDiameter: 44, agentMode: .column),
        // Greeting: bot drawn by GreetingCanvasView; no BotPlacement needed
        .greeting:  ViewLayout(height: 150, botX: 320, botY: 90,  botDiameter: 0,  agentMode: .none),
    ]

    // Project colors — keyed by lowercase display name or slug
    static let projectColors: [String: String] = [
        "korus":             "#FF5A4E",
        "sbe hub":           "#2EC4A0",
        "morning ai brief":  "#F29B38",
        "publication ig":    "#7C5CFF",
        "ig post":           "#7C5CFF",
        "louisraille.fr":    "#38BDF8",
        "louisraille":       "#38BDF8",
        "notch buddy":       "#EC4899",
        "notch-buddy":       "#EC4899",
        "notchbuddy":        "#EC4899",
    ]

    static let fallbackColors = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"]

    // Available integration pills (matches AgentTask.integrationAgents)
    struct IntegrationMeta {
        let id: String
        let name: String
        let color: String
    }
    static let allIntegrations: [IntegrationMeta] = [
        .init(id: "integration_resend",  name: "Resend",  color: "#22C55E"),
        .init(id: "integration_n8n",     name: "n8n",     color: "#F29B38"),
        .init(id: "integration_vercel",  name: "Vercel",  color: "#7C5CFF"),
        .init(id: "integration_github",  name: "GitHub",  color: "#F4505E"),
        .init(id: "integration_notion",  name: "Notion",  color: "#8C8C8C"),
        .init(id: "integration_calcom",  name: "Cal.com", color: "#C9956A"),
        .init(id: "integration_stripe",  name: "Stripe",  color: "#0570DE"),
        .init(id: "integration_slack",   name: "Slack",   color: "#4A154B"),
        .init(id: "integration_discord", name: "Discord", color: "#5865F2"),
        .init(id: "integration_telegram",name: "Telegram",color: "#0088CC"),
        .init(id: "integration_trello",  name: "Trello",  color: "#0079BF"),
        .init(id: "integration_linear",  name: "Linear",  color: "#000000"),
        .init(id: "integration_airtable",name: "Airtable",color: "#F3633B"),
        .init(id: "integration_supabase",name: "Supabase",color: "#3ECF8E"),
        .init(id: "integration_firebase",name: "Firebase",color: "#FFCA28"),
        .init(id: "integration_shopify", name: "Shopify", color: "#97BF0D"),
        .init(id: "integration_wordpress",name: "WordPress",color: "#21759B"),
        .init(id: "integration_dropbox", name: "Dropbox", color: "#0061EE"),
        .init(id: "integration_googledrive",name:"Google Drive",color: "#4285F4"),
        .init(id: "integration_gmail",   name: "Gmail",    color: "#EA4335"),
        .init(id: "integration_outlook", name: "Outlook",  color: "#0078D4"),
        .init(id: "integration_zoom",    name: "Zoom",     color: "#2D8CFF"),
        .init(id: "integration_asana",   name: "Asana",    color: "#F05620"),
        .init(id: "integration_jira",    name: "Jira",     color: "#0052CC"),
        .init(id: "integration_monday",  name: "Monday.com",color: "#5700D6"),
        .init(id: "integration_clickup", name: "ClickUp",   color: "#3FA6F8"),
        .init(id: "integration_hubspot", name: "HubSpot",   color: "#F56443"),
        .init(id: "integration_salesforce",name:"Salesforce",color: "#00A1E0"),
        .init(id: "integration_zendesk", name: "Zendesk",   color: "#0285CD"),
        .init(id: "integration_intercom",name: "Intercom",  color: "#037AFF"),
        .init(id: "integration_whatsapp",name: "WhatsApp",  color: "#25D366"),
        .init(id: "integration_pipedrive",name:"Pipedrive", color: "#E53435"),
        .init(id: "integration_mailchimp",name:"Mailchimp", color: "#F1673A"),
        .init(id: "integration_convertkit",name:"ConvertKit",color: "#0AB25D"),
        .init(id: "integration_patreon", name: "Patreon",   color: "#F96854"),
        .init(id: "integration_gumroad", name: "Gumroad",   color: "#522593"),
        .init(id: "integration_lemonsqueezy",name:"LemonSqueezy",color:"#4F46E5"),
        .init(id: "integration_quickbooks",name:"QuickBooks",color:"#0057FF"),
        .init(id: "integration_xero",    name: "Xero",       color: "#179BD7"),
        .init(id: "integration_paypal",  name: "PayPal",     color: "#0070BA"),
        .init(id: "integration_square",  name: "Square",     color: "#0078A8"),
        .init(id: "integration_typeform",name:"Typeform",     color: "#4267B2"),
        .init(id: "integration_jotform", name: "Jotform",    color: "#7C4DFF"),
        .init(id: "integration_mailerlite",name:"MailerLite",color: "#303F9F"),
        .init(id: "integration_activecampaign",name:"ActiveCampaign",color:"#17284A"),
        .init(id: "integration_zoho",    name: "Zoho",       color: "#E77000"),
        .init(id: "integration_freshdesk",name:"Freshdesk",   color: "#0061FF"),
    ]

    /// Returns the fixed project color for a display name, or a stable fallback.
    static func colorForProject(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = projectColors[key] { return c }
        // partial match (e.g. "korus-api" → "korus")
        for (k, c) in projectColors where key.hasPrefix(k) || key.contains(k) { return c }
        return fallbackColors[abs(name.hashValue) % fallbackColors.count]
    }

    // State card wash colors (radial gradient from bottom)
    static let washColors: [IslandView: String] = [
        .approval:  "rgba(245,165,36,0.42)",
        .question:  "rgba(34,211,238,0.38)",
        .error:     "rgba(244,80,94,0.55)",
        .finished:  "rgba(52,211,153,0.5)",
        .confused:  "rgba(244,114,182,0.55)",
        .searching: "rgba(99,102,241,0.5)",
        .result:    "rgba(52,211,153,0.22)",
        .prompt:    "rgba(99,102,241,0.22)",
    ]
}
