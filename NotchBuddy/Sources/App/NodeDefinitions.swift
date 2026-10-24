import Foundation

// MARK: - Node definitions (8 tipe node otomatisasi)

// Tipe node yang tersedia. Setiap tipe memiliki skema input dan output sendiri.
enum NodeType: String, Sendable, CaseIterable, Codable {
    case httpRequest   = "http_request"
    case fileSystem    = "file_system"
    case cronSchedule  = "cron_schedule"
    case ifElse        = "if_else"
    case jsonTransform = "json_transform"
    case desktopNotification = "desktop_notification"
    case clipboard     = "clipboard"
    case runShell      = "run_shell"
    // Integration nodes
    case slack         = "slack"
    case discord       = "discord"
    case telegram      = "telegram"
    case trello        = "trello"
    case linear        = "linear"
    case airtable      = "airtable"
    case supabase      = "supabase"
    case firebase      = "firebase"
    case shopify       = "shopify"
    case wordpress     = "wordpress"
    case dropbox       = "dropbox"
    case googledrive   = "googledrive"
    case gmail         = "gmail"
    case outlook       = "outlook"
    case zoom          = "zoom"
    case asana         = "asana"
    case jira          = "jira"
    case monday        = "monday"
    case clickup       = "clickup"
    case hubspot       = "hubspot"
    case salesforce    = "salesforce"
    case zendesk       = "zendesk"
    case intercom      = "intercom"
    case whatsapp      = "whatsapp"
    case pipedrive     = "pipedrive"
    case mailchimp     = "mailchimp"
    case convertkit    = "convertkit"
    case patreon       = "patreon"
    case gumroad       = "gumroad"
    case lemonsqueezy  = "lemonsqueezy"
    case quickbooks    = "quickbooks"
    case xero          = "xero"
    case paypal        = "paypal"
    case square        = "square"
    case typeform      = "typeform"
    case jotform       = "jotform"
    case mailerlite    = "mailerlite"
    case activecampaign = "activecampaign"
    case zoho          = "zoho"
    case freshdesk     = "freshdesk"

    var displayName: String {
        switch self {
        case .httpRequest:   return "HTTP Request"
        case .fileSystem:    return "File System"
        case .cronSchedule:  return "Cron Schedule"
        case .ifElse:        return "If / Else"
        case .jsonTransform: return "JSON Transform"
        case .desktopNotification: return "Desktop Notification"
        case .clipboard:     return "Clipboard"
        case .runShell:      return "Run Shell"
        case .slack:         return "Slack"
        case .discord:       return "Discord"
        case .telegram:      return "Telegram"
        case .trello:        return "Trello"
        case .linear:        return "Linear"
        case .airtable:      return "Airtable"
        case .supabase:      return "Supabase"
        case .firebase:      return "Firebase"
        case .shopify:       return "Shopify"
        case .wordpress:     return "WordPress"
        case .dropbox:       return "Dropbox"
        case .googledrive:   return "Google Drive"
        case .gmail:         return "Gmail"
        case .outlook:       return "Outlook"
        case .zoom:          return "Zoom"
        case .asana:         return "Asana"
        case .jira:          return "Jira"
        case .monday:        return "Monday.com"
        case .clickup:       return "ClickUp"
        case .hubspot:       return "HubSpot"
        case .salesforce:    return "Salesforce"
        case .zendesk:       return "Zendesk"
        case .intercom:      return "Intercom"
        case .whatsapp:      return "WhatsApp"
        case .pipedrive:     return "Pipedrive"
        case .mailchimp:     return "Mailchimp"
        case .convertkit:    return "ConvertKit"
        case .patreon:       return "Patreon"
        case .gumroad:       return "Gumroad"
        case .lemonsqueezy:  return "LemonSqueezy"
        case .quickbooks:    return "QuickBooks"
        case .xero:          return "Xero"
        case .paypal:        return "PayPal"
        case .square:        return "Square"
        case .typeform:      return "Typeform"
        case .jotform:       return "Jotform"
        case .mailerlite:    return "MailerLite"
        case .activecampaign:return "ActiveCampaign"
        case .zoho:          return "Zoho"
        case .freshdesk:     return "Freshdesk"
        }
    }

    var inputSchema: NodeInputSchema {
        switch self {
        case .httpRequest:   return .httpRequest
        case .fileSystem:    return .fileSystem
        case .cronSchedule:  return .cronSchedule
        case .ifElse:        return .ifElse
        case .jsonTransform: return .jsonTransform
        case .desktopNotification: return .desktopNotification
        case .clipboard:     return .clipboard
        case .runShell:      return .runShell
        case .slack:         return .slack
        case .discord:       return .discord
        case .telegram:      return .telegram
        case .trello:        return .trello
        case .linear:        return .linear
        case .airtable:      return .airtable
        case .supabase:      return .supabase
        case .firebase:      return .firebase
        case .shopify:       return .shopify
        case .wordpress:     return .wordpress
        case .dropbox:       return .dropbox
        case .googledrive:   return .googledrive
        case .gmail:         return .gmail
        case .outlook:       return .outlook
        case .zoom:          return .zoom
        case .asana:         return .asana
        case .jira:          return .jira
        case .monday:        return .monday
        case .clickup:       return .clickup
        case .hubspot:       return .hubspot
        case .salesforce:    return .salesforce
        case .zendesk:       return .zendesk
        case .intercom:      return .intercom
        case .whatsapp:      return .whatsapp
        case .pipedrive:     return .pipedrive
        case .mailchimp:     return .mailchimp
        case .convertkit:    return .convertkit
        case .patreon:       return .patreon
        case .gumroad:       return .gumroad
        case .lemonsqueezy:  return .lemonsqueezy
        case .quickbooks:    return .quickbooks
        case .xero:          return .xero
        case .paypal:        return .paypal
        case .square:        return .square
        case .typeform:      return .typeform
        case .jotform:       return .jotform
        case .mailerlite:    return .mailerlite
        case .activecampaign:return .activecampaign
        case .zoho:          return .zoho
        case .freshdesk:     return .freshdesk
        }
    }

    var description: String {
        switch self {
        case .httpRequest:   return "Kirim permintaan HTTP (GET/POST) ke URL mana saja."
        case .fileSystem:    return "Baca/tulis file lokal di Mac."
        case .cronSchedule:  return "Jalankan tugas berdasarkan jadwal (setiap X menit/jam)."
        case .ifElse:        return "Kondisi if/else berdasarkan output node sebelumnya."
        case .jsonTransform: return "Transformasi JSON menggunakan skrip JavaScript."
        case .desktopNotification: return "Tampilkan notifikasi desktop macOS."
        case .clipboard:     return "Baca/tulis papan klip (clipboard) macOS."
        case .runShell:      return "Jalankan perintah terminal (zsh)."
        case .slack:         return "Kirim pesan ke Slack channel."
        case .discord:       return "Kirim pesan ke Discord channel."
        case .telegram:      return "Kirim pesan ke Telegram chat."
        case .trello:        return "Kartu Trello: buat, lihat, perbarui kartu."
        case .linear:        return "Linear: buat, lihat, perbarui issue."
        case .airtable:      return "Airtable: baca, tulis, perbarui record."
        case .supabase:      return "Supabase: kueri, tulis data ke database."
        case .firebase:      return "Firebase: baca, tulis data ke Firestore."
        case .shopify:       return "Shopify: kelola produk, pesanan, pelanggan."
        case .wordpress:     return "WordPress: buat, perbarui posting dan halaman."
        case .dropbox:       return "Dropbox: baca, tulis, hapus file dan folder."
        case .googledrive:   return "Google Drive: baca, tulis, kelola file."
        case .gmail:         return "Gmail: baca, kirim email."
        case .outlook:       return "Outlook: baca, kirim email."
        case .zoom:          return "Zoom: kelola meeting dan webinar."
        case .asana:         return "Asana: buat, kelola tugas dan proyek."
        case .jira:          return "Jira: buat, kelola issue dan proyek."
        case .monday:        return "Monday.com: kelola papan dan item."
        case .clickup:       return "ClickUp: kelola tugas dan daftar."
        case .hubspot:       return "HubSpot: kelola kontak, deal, perusahaan."
        case .salesforce:    return "Salesforce: kelola lead, peluang, akun."
        case .zendesk:       return "Zendesk: kelola tiket dukungan."
        case .intercom:      return "Intercom: kelola percakapan pelanggan."
        case .whatsapp:      return "WhatsApp: kirim pesan WhatsApp."
        case .pipedrive:     return "Pipedrive: kelola deal dan pipeline."
        case .mailchimp:     return "Mailchimp: kelola kampanye email."
        case .convertkit:    return "ConvertKit: kelola pelanggan dan kampanye."
        case .patreon:       return "Patreon: kelola anggota dan kreator."
        case .gumroad:       return "Gumroad: kelola produk dan penjualan."
        case .lemonsqueezy:  return "Lemon Squeezy: kelola produk dan pesanan."
        case .quickbooks:    return "QuickBooks: kelola faktur dan pelanggan."
        case .xero:          return "Xero: kelola faktur dan kontak."
        case .paypal:        return "PayPal: kelola transaksi pembayaran."
        case .square:        return "Square: kelola pembayaran dan pesanan."
        case .typeform:      return "Typeform: buat dan kelola formulir."
        case .jotform:       return "Jotform: buat dan kelola formulir online."
        case .mailerlite:    return "MailerLite: kelola kampanye email."
        case .activecampaign:return "ActiveCampaign: kelola otomatisasi pemasaran."
        case .zoho:          return "Zoho: kelola CRM dan bisnis."
        case .freshdesk:     return "Freshdesk: kelola tiket dukungan pelanggan."
        }
    }
}

/// Input node — nilai yang dilewatkan ke node saat eksekusi.
struct NodeInput: Equatable, Sendable {
    var values: [String: JSONValue]
}

/// Output node — hasil eksekusi.
struct NodeOutput: Equatable, Sendable {
    var values: [String: JSONValue]
    var isError: Bool
    var errorMessage: String?
}

/// Skema input untuk setiap tipe node (digunakan untuk validasi dan dokumentasi UI).
enum NodeInputSchema: Sendable {
    case httpRequest, fileSystem, cronSchedule, ifElse, jsonTransform,
         desktopNotification, clipboard, runShell,
         slack, discord, telegram, trello, linear, airtable, supabase, firebase,
         shopify, wordpress, dropbox, googledrive, gmail, outlook, zoom,
         asana, jira, monday, clickup, hubspot, salesforce, zendesk, intercom,
         whatsapp, pipedrive, mailchimp, convertkit, patreon, gumroad,
         lemonsqueezy, quickbooks, xero, paypal, square, typeform, jotform,
         mailerlite, activecampaign, zoho, freshdesk

    var requiredKeys: [String] {
        switch self {
        case .httpRequest:   return ["url", "method"]
        case .fileSystem:    return ["operation", "path"]
        case .cronSchedule:  return ["interval", "unit"]
        case .ifElse:        return ["condition", "trueBranch", "falseBranch"]
        case .jsonTransform: return ["input", "script"]
        case .desktopNotification: return ["title", "body"]
        case .clipboard:     return ["operation", "text"]
        case .runShell:      return ["command"]
        case .slack:         return ["channel", "text"]
        case .discord:       return ["channel_id", "content"]
        case .telegram:      return ["chat_id", "text"]
        case .trello:        return ["idList", "name"]
        case .linear:        return ["teamId", "title"]
        case .airtable:      return ["baseId", "tableId"]
        case .supabase:      return ["table"]
        case .firebase:      return ["projectId"]
        case .shopify:       return ["shop"]
        case .wordpress:     return ["site"]
        case .dropbox:       return ["path"]
        case .googledrive:   return ["fileId"]
        case .gmail:         return ["query"]
        case .outlook:       return ["folder"]
        case .zoom:          return ["topic"]
        case .asana:         return ["workspace", "name"]
        case .jira:          return ["project", "summary"]
        case .monday:        return ["boardId", "itemName"]
        case .clickup:       return ["listId", "name"]
        case .hubspot:       return ["objectType"]
        case .salesforce:    return ["objectType", "query"]
        case .zendesk:       return ["subject", "requester_id"]
        case .intercom:      return ["conversation_id"]
        case .whatsapp:      return ["phone", "body"]
        case .pipedrive:     return ["title"]
        case .mailchimp:     return ["listId"]
        case .convertkit:    return ["formId"]
        case .patreon:       return ["creatorId"]
        case .gumroad:       return ["productId"]
        case .lemonsqueezy:  return ["storeId"]
        case .quickbooks:    return ["companyId"]
        case .xero:          return ["tenantId"]
        case .paypal:        return ["orderId"]
        case .square:        return ["orderId"]
        case .typeform:      return ["formId"]
        case .jotform:       return ["formId"]
        case .mailerlite:    return ["campaignId"]
        case .activecampaign:return ["listId"]
        case .zoho:          return ["module"]
        case .freshdesk:     return ["subject"]
        }
    }

    var outputKeys: [String] {
        switch self {
        case .httpRequest:   return ["statusCode", "body", "headers"]
        case .fileSystem:    return ["content", "exists", "size"]
        case .cronSchedule:  return ["nextRun", "scheduled"]
        case .ifElse:        return ["result", "branchTaken"]
        case .jsonTransform: return ["output"]
        case .desktopNotification: return ["delivered"]
        case .clipboard:     return ["content", "success"]
        case .runShell:      return ["output", "exitCode"]
        case .slack:         return ["text", "ts", "channel"]
        case .discord:       return ["id", "content", "author"]
        case .telegram:      return ["message_id", "text", "from"]
        case .trello:        return ["id", "name", "desc", "url"]
        case .linear:        return ["id", "title", "state", "url"]
        case .airtable:      return ["id", "fields", "createdTime"]
        case .supabase:      return ["id", "data", "created_at"]
        case .firebase:      return ["name", "createTime", "updateTime"]
        case .shopify:       return ["id", "title", "status", "total_price"]
        case .wordpress:     return ["id", "title", "content", "date"]
        case .dropbox:       return ["id", "name", "path_lower", "size"]
        case .googledrive:   return ["id", "name", "mimeType", "size"]
        case .gmail:         return ["id", "subject", "snippet", "date"]
        case .outlook:       return ["id", "subject", "bodyPreview", "receivedDateTime"]
        case .zoom:          return ["id", "topic", "start_time", "url"]
        case .asana:         return ["id", "name", "notes", "completed"]
        case .jira:          return ["id", "key", "summary", "status"]
        case .monday:        return ["id", "name", "state", "url"]
        case .clickup:       return ["id", "name", "status", "url"]
        case .hubspot:       return ["id", "properties", "createdate"]
        case .salesforce:    return ["id", "Name", "Status", "CreatedDate"]
        case .zendesk:       return ["id", "subject", "status", "created_at"]
        case .intercom:      return ["id", "subject", "body", "created_at"]
        case .whatsapp:      return ["id", "body", "timestamp"]
        case .pipedrive:     return ["id", "title", "status", "value"]
        case .mailchimp:     return ["id", "title", "status", "send_time"]
        case .convertkit:    return ["id", "name", "state", "created_at"]
        case .patreon:       return ["id", "name", "status", "created_at"]
        case .gumroad:       return ["id", "name", "status", "created_at"]
        case .lemonsqueezy:  return ["id", "name", "status", "created_at"]
        case .quickbooks:    return ["Id", "DisplayName", "Status", "Balance"]
        case .xero:          return ["ContactID", "Name", "Status", "Balance"]
        case .paypal:        return ["id", "status", "amount", "create_time"]
        case .square:        return ["id", "state", "total_money", "created_at"]
        case .typeform:      return ["id", "title", "settings", "created_at"]
        case .jotform:       return ["id", "title", "status", "created_at"]
        case .mailerlite:    return ["id", "name", "status", "created_at"]
        case .activecampaign:return ["id", "title", "status", "created_at"]
        case .zoho:          return ["id", "name", "status", "created_time"]
        case .freshdesk:     return ["id", "subject", "status", "created_at"]
        }
    }
}

/// Deskripsi lengkap satu node dalam workflow otomatisasi.
struct NodeDefinition: Identifiable, Equatable, Sendable {
    var id: String
    var type: NodeType
    var name: String
    var config: [String: JSONValue]  // konfigurasi node (mis. URL untuk http_request)
    var enabled: Bool = true

    var inputSchema: NodeInputSchema {
        switch type {
        case .httpRequest:   return .httpRequest
        case .fileSystem:    return .fileSystem
        case .cronSchedule:  return .cronSchedule
        case .ifElse:        return .ifElse
        case .jsonTransform: return .jsonTransform
        case .desktopNotification: return .desktopNotification
        case .clipboard:     return .clipboard
        case .runShell:      return .runShell
        case .slack:         return .slack
        case .discord:       return .discord
        case .telegram:      return .telegram
        case .trello:        return .trello
        case .linear:        return .linear
        case .airtable:      return .airtable
        case .supabase:      return .supabase
        case .firebase:      return .firebase
        case .shopify:       return .shopify
        case .wordpress:     return .wordpress
        case .dropbox:       return .dropbox
        case .googledrive:   return .googledrive
        case .gmail:         return .gmail
        case .outlook:       return .outlook
        case .zoom:          return .zoom
        case .asana:         return .asana
        case .jira:          return .jira
        case .monday:        return .monday
        case .clickup:       return .clickup
        case .hubspot:       return .hubspot
        case .salesforce:    return .salesforce
        case .zendesk:       return .zendesk
        case .intercom:      return .intercom
        case .whatsapp:      return .whatsapp
        case .pipedrive:     return .pipedrive
        case .mailchimp:     return .mailchimp
        case .convertkit:    return .convertkit
        case .patreon:       return .patreon
        case .gumroad:       return .gumroad
        case .lemonsqueezy:  return .lemonsqueezy
        case .quickbooks:    return .quickbooks
        case .xero:          return .xero
        case .paypal:        return .paypal
        case .square:        return .square
        case .typeform:      return .typeform
        case .jotform:       return .jotform
        case .mailerlite:    return .mailerlite
        case .activecampaign:return .activecampaign
        case .zoho:          return .zoho
        case .freshdesk:     return .freshdesk
        }
    }
}

/// Satu node dalam alur kerja otomatisasi (workflow). Node-node dihubungkan
/// melalui output → input dari node lain.
struct AutomationNode: Identifiable, Equatable, Sendable {
    var id: String
    var nodeDefinitionId: String  // merujuk ke NodeDefinition
    var positionX: Double = 0
    var positionY: Double = 0
    var enabled: Bool = true
}

/// Alur kerja otomatisasi: kumpulan node yang dijalankan berurutan atau berdasarkan
/// kondisi. Dijalankan melalui ToolExecutor (PolicyEngine + AuditLog tetap berlaku).
struct AutomationWorkflow: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var nodes: [AutomationNode] = []
    var edges: [WorkflowEdge] = []  // nodeA.id → nodeB.id
    var enabled: Bool = true
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// Sisi dalam workflow — output node sumber menjadi input node tujuan.
struct WorkflowEdge: Identifiable, Equatable, Sendable {
    var id: String
    var sourceNodeId: String
    var sourceOutputKey: String
    var targetNodeId: String
    var targetInputKey: String
}
