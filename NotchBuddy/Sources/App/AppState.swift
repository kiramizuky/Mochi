import Foundation
import SwiftUI
import Combine

// Integration pills — always-present, never purged
extension AgentTask {
    /// All available integration pills. Claude is always active; others are opt-in (max 4).
    static let integrationAgents: [AgentTask] = [
        AgentTask(id: "integration_claude",  name: "VS Code",   color: "#F5F6F8", state: .idle, steps: [], source: .claudeCode, isIntegration: true),
        AgentTask(id: "integration_resend",  name: "Resend",    color: "#22C55E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_n8n",     name: "n8n",       color: "#F29B38", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_vercel",  name: "Vercel",    color: "#7C5CFF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_github",  name: "GitHub",    color: "#F4505E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_notion",  name: "Notion",    color: "#8C8C8C", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_calcom",  name: "Cal.com",   color: "#C9956A", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_stripe",  name: "Stripe",    color: "#0570DE", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_slack",   name: "Slack",     color: "#4A154B", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_discord", name: "Discord",   color: "#5865F2", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_telegram",name: "Telegram",  color: "#0088CC", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_trello",  name: "Trello",    color: "#0079BF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_linear",  name: "Linear",    color: "#000000", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_airtable",name: "Airtable",   color: "#F3633B", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_supabase",name: "Supabase",   color: "#3ECF8E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_firebase",name: "Firebase",   color: "#FFCA28", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_shopify", name: "Shopify",    color: "#97BF0D", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_wordpress",name: "WordPress", color: "#21759B", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_dropbox", name: "Dropbox",    color: "#0061EE", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_googledrive",name:"Google Drive",color: "#4285F4", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_gmail",   name: "Gmail",      color: "#EA4335", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_outlook", name: "Outlook",    color: "#0078D4", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_zoom",    name: "Zoom",       color: "#2D8CFF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_asana",   name: "Asana",      color: "#F05620", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_jira",    name: "Jira",       color: "#0052CC", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_monday",  name: "Monday.com", color: "#5700D6", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_clickup", name: "ClickUp",    color: "#3FA6F8", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_hubspot", name: "HubSpot",    color: "#F56443", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_salesforce",name:"Salesforce",color: "#00A1E0", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_zendesk", name: "Zendesk",    color: "#0285CD", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_intercom",name: "Intercom",   color: "#037AFF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_whatsapp",name: "WhatsApp",   color: "#25D366", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_pipedrive",name:"Pipedrive",  color: "#E53435", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_mailchimp",name:"Mailchimp",  color: "#F1673A", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_convertkit",name:"ConvertKit",color: "#0AB25D", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_patreon", name: "Patreon",    color: "#F96854", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_gumroad", name: "Gumroad",    color: "#522593", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_lemonsqueezy",name:"LemonSqueezy",color:"#4F46E5",state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_quickbooks",name:"QuickBooks",color: "#0057FF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_xero",    name: "Xero",       color: "#179BD7", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_paypal",  name: "PayPal",     color: "#0070BA", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_square",  name: "Square",     color: "#0078A8", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_typeform",name:"Typeform",    color: "#4267B2", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_jotform", name: "Jotform",    color: "#7C4DFF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_mailerlite",name:"MailerLite",color: "#303F9F", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_activecampaign",name:"ActiveCampaign",color:"#17284A",state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_zoho",    name: "Zoho",       color: "#E77000", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_freshdesk",name:"Freshdesk",   color: "#0061FF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_pipedrive",name:"Pipedrive",  color: "#E53435", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_word",    name: "Word",      color: "#2E74B5", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_excel",   name: "Excel",     color: "#107C41", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_powerpoint", name: "PowerPoint",color: "#C6434C", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_outlook_office", name: "Outlook", color: "#0078D4", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_code_editor", name: "VS Code", color: "#007ACC", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_vscode", name: "VS Code Insiders", color: "#007ACC", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_pycharm", name: "PyCharm", color: "#037ACC", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_intellij", name: "IntelliJ IDEA", color: "#04799D", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_sublime", name: "Sublime Text", color: "#FF7B0B", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_vim", name: "Vim", color: "#019739", state: .idle, steps: [], source: .app, isIntegration: true),
        AgentTask(id: "integration_emacs", name: "Emacs", color: "#519ABA", state: .idle, steps: [], source: .app, isIntegration: true),
    ]

    /// IDs that can be toggled (VS Code is always on and excluded from this list)
    static let toggleableIntegrationIds: [String] = [
        "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
        "integration_notion", "integration_calcom", "integration_stripe",
        "integration_slack", "integration_discord", "integration_telegram",
        "integration_trello", "integration_linear", "integration_airtable",
        "integration_supabase", "integration_firebase", "integration_shopify",
        "integration_wordpress", "integration_dropbox", "integration_googledrive",
        "integration_gmail", "integration_outlook", "integration_zoom",
        "integration_asana", "integration_jira", "integration_monday",
        "integration_clickup", "integration_hubspot", "integration_salesforce",
        "integration_zendesk", "integration_intercom", "integration_whatsapp",
        "integration_pipedrive", "integration_mailchimp", "integration_convertkit",
        "integration_patreon", "integration_gumroad", "integration_lemonsqueezy",
        "integration_quickbooks", "integration_xero", "integration_paypal",
        "integration_square", "integration_typeform", "integration_jotform",
        "integration_mailerlite", "integration_activecampaign", "integration_zoho",
        "integration_freshdesk", "integration_pipedrive",
        "integration_word", "integration_excel", "integration_powerpoint",
        "integration_outlook_office", "integration_powerpoint_online",
        "integration_word_online", "integration_excel_online",
        "integration_code_editor", "integration_vscode", "integration_pycharm",
        "integration_intellij", "integration_sublime", "integration_vim",
        "integration_emacs",
    ]

    /// Poll configurations for each integration. Used by GenericIntegrationPoller.
    static let integrationPollConfigs: [GenericIntegrationPoller.IntegrationPollConfig] = [
        // Claude Code - polled via HookServer (no poller needed)
        // Resend - polled via ResendPoller (already exists)
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_n8n",
            endpoint: "", // Has its own N8nPoller
            apiKeyName: "n8n-api-key",
            apiKeyHeader: "X-N8N-API-KEY",
            valuePath: "",
            pollInterval: 15
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_vercel",
            endpoint: "https://api.vercel.com/v1/projects",
            apiKeyName: "vercel-token",
            apiKeyHeader: "Authorization",
            valuePath: "projects.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_github",
            endpoint: "https://api.github.com/user/repos?per_page=1",
            apiKeyName: "github-token",
            apiKeyHeader: "Authorization",
            valuePath: "0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_notion",
            endpoint: "https://api.notion.com/v1/search",
            apiKeyName: "notion-api-key",
            apiKeyHeader: "Notion-Version",
            valuePath: "results.0.properties.Name.title.0.plain_text",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_calcom",
            endpoint: "https://api.cal.com/v1/bookings",
            apiKeyName: "calcom-api-key",
            apiKeyHeader: "Cal-Api-Key",
            valuePath: "bookings.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_stripe",
            endpoint: "https://api.stripe.com/v1/charges?limit=1",
            apiKeyName: "stripe-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.description",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_slack",
            endpoint: "https://slack.com/api/conversations.history?limit=1",
            apiKeyName: "slack-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "messages.0.text",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_discord",
            endpoint: "https://discord.com/api/v9/channels/unknown/messages?limit=1",
            apiKeyName: "discord-bot-token",
            apiKeyHeader: "Authorization",
            valuePath: "0.content",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_telegram",
            endpoint: "https://api.telegram.org/bot<token>/getUpdates?limit=1",
            apiKeyName: "telegram-bot-token",
            apiKeyHeader: "",
            valuePath: "result.0.message.text",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_trello",
            endpoint: "https://api.trello.com/1/members/me/actions?limit=1",
            apiKeyName: "trello-api-key",
            apiKeyHeader: "",
            valuePath: "0.data.card.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_linear",
            endpoint: "https://api.linear.app/graphql",
            apiKeyName: "linear-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.issues.nodes.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_airtable",
            endpoint: "https://api.airtable.com/v0/meta/bases",
            apiKeyName: "airtable-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "bases.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_supabase",
            endpoint: "https://api.supabase.com/v1/projects",
            apiKeyName: "supabase-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_firebase",
            endpoint: "https://firebase.googleapis.com/v1/projects",
            apiKeyName: "firebase-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_shopify",
            endpoint: "https://api.shopify.com/admin/api/2023-10/orders.json?limit=1",
            apiKeyName: "shopify-api-key",
            apiKeyHeader: "X-Shopify-Access-Token",
            valuePath: "orders.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_wordpress",
            endpoint: "https://api.wordpress.org/sites/v1/posts?per_page=1",
            apiKeyName: "wordpress-api-key",
            apiKeyHeader: "",
            valuePath: "0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_dropbox",
            endpoint: "https://api.dropboxapi.com/2/files/list_folder",
            apiKeyName: "dropbox-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "entries.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_googledrive",
            endpoint: "https://www.googleapis.com/drive/v3/files?maxResults=1",
            apiKeyName: "googledrive-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "files.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_gmail",
            endpoint: "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=1",
            apiKeyName: "gmail-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "messages.0.id",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_outlook",
            endpoint: "https://graph.microsoft.com/v1/me/messages?$top=1",
            apiKeyName: "outlook-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.subject",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_zoom",
            endpoint: "https://api.zoom.us/v2/users/me/meetings",
            apiKeyName: "zoom-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "meetings.0.topic",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_asana",
            endpoint: "https://app.asana.com/api/1.0/tasks?limit=1",
            apiKeyName: "asana-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_jira",
            endpoint: "https://api.atlassian.com/rest/api/2/search?maxResults=1",
            apiKeyName: "jira-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "issues.0.fields.summary",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_monday",
            endpoint: "https://api.monday.com/v2",
            apiKeyName: "monday-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.boards.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_clickup",
            endpoint: "https://api.clickup.com/api/v2/list/unknown/task",
            apiKeyName: "clickup-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "tasks.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_hubspot",
            endpoint: "https://api.hubapi.com/crm/v3/objects/contacts?limit=1",
            apiKeyName: "hubspot-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "results.0.properties.firstname",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_salesforce",
            endpoint: "https://api.salesforce.com/services/data/v58.0/query?q=SELECT+Name+FROM+Account+LIMIT+1",
            apiKeyName: "salesforce-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "records.0.Name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_zendesk",
            endpoint: "https://api.zendesk.com/api/v2/tickets.json?limit=1",
            apiKeyName: "zendesk-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "tickets.0.subject",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_intercom",
            endpoint: "https://api.intercom.io/conversations?per_page=1",
            apiKeyName: "intercom-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_whatsapp",
            endpoint: "https://graph.facebook.com/v18.0/me/messages",
            apiKeyName: "whatsapp-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.text",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_pipedrive",
            endpoint: "https://api.pipedrive.com/v1/deals?limit=1",
            apiKeyName: "pipedrive-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_mailchimp",
            endpoint: "https://api.mailchimp.com/3.0/campaigns?count=1",
            apiKeyName: "mailchimp-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "campaigns.0.settings.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_convertkit",
            endpoint: "https://api.convertkit.com/v3/forms",
            apiKeyName: "convertkit-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "forms.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_patreon",
            endpoint: "https://www.patreon.com/api/oauth2/v2/campaigns",
            apiKeyName: "patreon-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.attributes.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_gumroad",
            endpoint: "https://api.gumroad.com/v2/products",
            apiKeyName: "gumroad-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "products.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_lemonsqueezy",
            endpoint: "https://api.lemonsqueezy.com/v1/products",
            apiKeyName: "lemonsqueezy-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.attributes.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_quickbooks",
            endpoint: "https://quickbooks.api.intuit.com/v3/company/unknown/query?query=SELECT+Name+FROM+Customer+LIMIT+1",
            apiKeyName: "quickbooks-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "QueryResponse.Customer.0.Name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_xero",
            endpoint: "https://api.xero.com/api.xro/2.0/Contacts",
            apiKeyName: "xero-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "Response.Contacts.0.Name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_paypal",
            endpoint: "https://api-m.paypal.com/v1/reporting/transactions?start_date=2024-01-01&end_date=2024-12-31&page_size=1",
            apiKeyName: "paypal-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "transactions.0.transaction_info.transaction_id",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_square",
            endpoint: "https://connect.squareup.com/v2/orders/search",
            apiKeyName: "square-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "orders.0.order_id",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_typeform",
            endpoint: "https://api.typeform.com/forms",
            apiKeyName: "typeform-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "items.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_jotform",
            endpoint: "https://api.jotform.com/forms",
            apiKeyName: "jotform-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "content.0.title",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_mailerlite",
            endpoint: "https://api.mailerlite.com/api/v2/campaigns?limit=1",
            apiKeyName: "mailerlite-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_activecampaign",
            endpoint: "https://api.activecampaign.com/api/3/contacts?limit=1",
            apiKeyName: "activecampaign-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "contacts.0.first_name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_zoho",
            endpoint: "https://www.zohoapis.com/crm/v2/Accounts?per_page=1",
            apiKeyName: "zoho-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "data.0.Account_Name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_freshdesk",
            endpoint: "https://api.freshdesk.com/api/v2/tickets?per_page=1",
            apiKeyName: "freshdesk-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "0.subject",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_word",
            endpoint: "https://graph.microsoft.com/v1/me/drive/root/search('word')?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_excel",
            endpoint: "https://graph.microsoft.com/v1/me/drive/root/search('excel')?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_powerpoint",
            endpoint: "https://graph.microsoft.com/v1/me/drive/root/search('ppt')?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_outlook_office",
            endpoint: "https://graph.microsoft.com/v1/me/messages?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.subject",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_powerpoint_online",
            endpoint: "https://graph.microsoft.com/v1/me/drive/root/search('pptx')?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_word_online",
            endpoint: "https://graph.microsoft.com/v1/me/drive/root/search('docx')?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.name",
            pollInterval: 30
        ),
        GenericIntegrationPoller.IntegrationPollConfig(
            id: "integration_excel_online",
            endpoint: "https://graph.microsoft.com/v1/me/drive/root/search('xlsx')?$top=1",
            apiKeyName: "office-api-key",
            apiKeyHeader: "Authorization",
            valuePath: "value.0.name",
            pollInterval: 30
        ),
    ]

}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Media Player & Notch Studio State
    @Published var activeMediaItem: MediaItem? = nil
    @Published var isMediaPlaying: Bool = false
    @Published var mediaPlaybackPosition: Double = 0.0
    @Published var mediaDuration: Double = 0.0

    // Bot state override
    @Published var stateOverride: BotState? = nil
    @Published var activePlaybookProgress: String? = nil

    // Telegram Mobile Gateway Pairing State
    @Published var telegramPairingPIN: String? = nil
    @Published var telegramPairingChatName: String? = nil
    @Published var telegramPairingExpiration: Date? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before NotchBuddy (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    @Published var uploadProgress: Double = 0

    // Upload animation timing (non-published — TimelineViews read these directly)
    var uploadStartTime: Date?
    var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    @Published var fileDragOver: Bool = false

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Claude model used by the chat and the search — persisted
    static let defaultClaudeModel = "claude-sonnet-4-6"
    @Published var claudeModel: String = AppState.defaultClaudeModel {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Prefill dari chip proaktif (diklik chip → isi field + buka view prompt)
    @Published var promptPrefill: String? = nil

    // Chip proaktif dari memori jangka panjang (waktu / janji)
    @Published var proactiveChips: [ProactiveChip] = []

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    @Published var allowAllEditors: Bool = UserDefaults.standard.object(forKey: "allowAllEditors") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowAllEditors, forKey: "allowAllEditors") }
    }
    @Published var preferredEditor: String = UserDefaults.standard.string(forKey: "preferredEditor") ?? "auto" {
        didSet { UserDefaults.standard.set(preferredEditor, forKey: "preferredEditor") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Tab pengaturan aktif (untuk navigasi langsung dari Island ke Full Settings Window)
    @Published var selectedSettingsTab: SettingsTab = .general

    // Onboarding selesai? Saat pertama kali diluncurkan → false, Settings
    // menampilkan alur onboarding (API key, izin, mode autopilot).
    @Published var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: "hasOnboarded") {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "hasOnboarded") }
    }

    // Mode otonom aktif? Default ON (super autonomous) — tanpa campur tangan user.
    @Published var autonomousEnabled: Bool = UserDefaults.standard.object(forKey: "autonomousEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autonomousEnabled, forKey: "autonomousEnabled") }
    }

    // Mode otopilot (autopilot) untuk PolicyEngine. Default ON (super autonomous).
    @Published var autopilotEnabled: Bool = UserDefaults.standard.object(forKey: "autopilotEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autopilotEnabled, forKey: "autopilotEnabled")
            applyAutopilotMode()
        }
    }

    /// Batas langkah agent per permintaan pengguna (AgentController.maxSteps).
    @Published var agentStepLimit: Int = UserDefaults.standard.integer(forKey: "agentStepLimit") {
        didSet {
            let v = max(1, agentStepLimit)
            if v != agentStepLimit { agentStepLimit = v }
            UserDefaults.standard.set(v, forKey: "agentStepLimit")
        }
    }

    func applyAutopilotMode() {
        if autopilotEnabled {
            PolicyEngine.defaultModes[.shell] = .autopilot
            PolicyEngine.defaultModes[.email] = .autopilot
            PolicyEngine.defaultModes[.network] = .autopilot
            PolicyEngine.defaultModes[.fileWrite] = .askOnce
            PolicyEngine.defaultModes[.appControl] = .askOnce
        } else {
            PolicyEngine.defaultModes[.shell] = .askOnce
            PolicyEngine.defaultModes[.email] = .askOnce
            PolicyEngine.defaultModes[.network] = .askOnce
            PolicyEngine.defaultModes[.fileWrite] = .askOnce
            PolicyEngine.defaultModes[.appControl] = .askOnce
        }
    }

    // Daftar tugas otonom (dari scheduler / chip proaktif / perintah suara).
    @Published var autonomousTasks: [AutonomousTask] = []

    // Konfigurasi server MCP klien (Coucou sebagai klien ke server eksternal).
    @Published var mcpServers: [MCPServerConfig] = [] {
        didSet { saveMcpServers() }
    }
    // Expose Coucou sebagai server MCP (stdio) untuk agen eksternal.
    @Published var mcpServerEnabled: Bool = false {
        didSet { UserDefaults.standard.set(mcpServerEnabled, forKey: "mcpServerEnabled") }
    }
    @Published var mcpServerPort: Int = 18765 {
        didSet { UserDefaults.standard.set(mcpServerPort, forKey: "mcpServerPort") }
    }

    private func saveMcpServers() {
        if let data = try? JSONEncoder().encode(mcpServers) {
            UserDefaults.standard.set(data, forKey: "mcpServers")
        }
    }

    // Vercel project filter — empty = watch all projects
    @Published var vercelProjectFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(vercelProjectFilter)) {
                UserDefaults.standard.set(data, forKey: "vercelProjectFilter")
            }
        }
    }

    // n8n workflow filter — empty = watch all workflows
    @Published var n8nWorkflowFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(n8nWorkflowFilter)) {
                UserDefaults.standard.set(data, forKey: "n8nWorkflowFilter")
            }
        }
    }

    // Active integration pills (VS Code excluded — always on). Max 4.
    @Published var activeIntegrations: Set<String> = ["integration_resend", "integration_n8n", "integration_vercel", "integration_github"] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(activeIntegrations)) {
                UserDefaults.standard.set(data, forKey: "activeIntegrations")
            }
        }
    }

    // Pending API result
    @Published var searchResult: SearchResult? = nil

    // Vercel deployments (populated by VercelPoller)
    @Published var vercelDeployments: [VercelDeployment] = []

    // Resend emails (populated by ResendPoller)
    @Published var resendEmails: [ResendEmail] = []
    @Published var resendTotal: Int? = nil

    // GitHub stats (populated by GithubPoller)
    @Published var githubStats: GitHubStats? = nil

    // Stripe (populated by StripePoller)
    @Published var stripePayments: [StripePayment] = []
    @Published var stripeBalance: Int = 0           // raw balance in cents
    @Published var stripeDisplayBalance: Int = 0    // animated balance target
    @Published var stripeCurrency: String = "eur"
    @Published var stripeLoaded: Bool = false       // true after first successful poll
    @Published var stripeError: String? = nil      // last API error (nil = ok)

    // Cal.com (populated by CalcomPoller)
    @Published var calcomBookings: [CalcomBooking] = []
    @Published var calcomLoaded: Bool = false
    @Published var calcomError: String? = nil

    // Notion (populated by NotionPoller)
    @Published var notionPages: [NotionPage] = []
    @Published var notionLoaded: Bool = false
    @Published var notionError: String? = nil

    // Chat conversation history
    @Published var chatHistory: [ChatMessage] = []

    // Menandakan apakah AI sedang men-generate atau streaming jawaban
    @Published var isGenerating: Bool = false

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // Agent tool confirmation awaiting a click (non-published by design)
    var agentApproval: CheckedContinuation<Bool, Never>? = nil

    /// Resume the agent tool confirmation. Idempotent: safe to call twice,
    /// and never touches the hook (Claude Code) approval UI.
    func answerAgentApproval(_ approved: Bool) {
        let cont = agentApproval
        agentApproval = nil
        if pendingApproval?.source == .agent {
            pendingApproval = nil
            if view == .approval { view = .prompt }
        }
        cont?.resume(returning: approved)
    }

    /// Eksekusi perintah suara atau teks secara langsung (hands-free)
    func executeCommand(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if mode == .hidden || mode == .compact {
            NotificationCenter.default.post(name: .voiceWake, object: nil)
        } else {
            view = .prompt
        }
        lastActivity = .now
        chatHistory.append(ChatMessage(role: .user, content: trimmed))
        stateOverride = .thinking

        Task {
            await ClaudeService.shared.chat(query: trimmed, context: promptContext, state: self)
        }
    }

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        if let v = ud.string(forKey: "claudeModel"),
           !v.trimmingCharacters(in: .whitespaces).isEmpty { claudeModel = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let d = ud.data(forKey: "vercelProjectFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { vercelProjectFilter = Set(a) }
        if let d = ud.data(forKey: "n8nWorkflowFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { n8nWorkflowFilter = Set(a) }
        if let d = ud.data(forKey: "activeIntegrations"),
           let a = try? JSONDecoder().decode([String].self, from: d) { activeIntegrations = Set(a) }

        // Terapkan mode otopilot yang tersimpan ke PolicyEngine.
        applyAutopilotMode()

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        if let stateOverride { return stateOverride }
        if VoiceDuplexEngine.shared.isInterrupted { return .question }
        if VoiceManager.shared.pttStatus == .listening { return .searching }
        if VoiceManager.shared.isSpeaking { return .working }
        return focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = tasks.first?.id }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && (mode == .compact || mode == .peek) {
            mode = .hidden
        } else if !tasks.isEmpty && (mode == .hidden || mode == .peek) && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load integration pills respecting activeIntegrations. VS Code always loads. Safe to call multiple times.
    func loadIntegrationTasks() {
        for task in AgentTask.integrationAgents {
            let shouldLoad = task.id == "integration_claude" || activeIntegrations.contains(task.id)
            let loaded = tasks.contains(where: { $0.id == task.id })
            if shouldLoad && !loaded { tasks.append(task) }
            if !shouldLoad && loaded { tasks.removeAll { $0.id == task.id } }
        }
        if focusId == nil { focusId = "integration_claude" }
        syncMode()
    }

    /// Toggle an integration pill on/off. VS Code cannot be toggled. Max 8 active at once.
    func toggleIntegration(_ id: String) {
        guard id != "integration_claude" else { return }
        if activeIntegrations.contains(id) {
            activeIntegrations.remove(id)
            tasks.removeAll { $0.id == id }
            if focusId == id { focusId = "integration_claude" }
        } else {
            guard activeIntegrations.count < 8 else { return }
            activeIntegrations.insert(id)
            if let task = AgentTask.integrationAgents.first(where: { $0.id == id }),
               !tasks.contains(where: { $0.id == id }) {
                tasks.append(task)
            }
        }
        syncMode()
    }

}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
}

struct DroppedFile {
    var url: URL
    var name: String
}

struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

struct VercelDeployment: Identifiable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // "READY", "ERROR", "CANCELED"
    let createdAt: Date
    let commitMessage: String?
    let branch: String?

    var isSuccess: Bool { state == "READY" }
    var statusLabel: String { isSuccess ? "Ready" : (state == "CANCELED" ? "Canceled" : "Error") }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Resend

struct ResendEmail: Identifiable {
    let id: String
    let to: [String]
    let subject: String
    let createdAt: Date
    let lastEvent: String   // "delivered", "bounced", "complained", "opened", etc.

    var recipientShort: String {
        guard let first = to.first else { return "?" }
        return first.components(separatedBy: "@").first ?? first
    }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
    var isDelivered: Bool { lastEvent == "delivered" }
}

// MARK: - GitHub

struct GitHubStats {
    let totalRepos: Int
    let totalStars: Int
}

// MARK: - Stripe

struct StripePayment: Identifiable, Equatable {
    let id: String
    let amount: Int         // in cents/smallest unit
    let currency: String
    let description: String?
    let createdAt: Date
    let status: String      // "succeeded", "pending", "failed"

    var amountFormatted: String { String(format: "%.2f", Double(amount) / 100.0) }
    var isSuccess: Bool { status == "succeeded" }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Cal.com

struct CalcomBooking: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Date
    let endTime: Date
    let status: String
    let attendeeName: String?
    let attendeeEmail: String?
    let attendeeNotes: String?

    var isActive: Bool { status == "ACCEPTED" || status == "PENDING" }
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: startTime)
    }
    var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: startTime)
        guard let year = c.year, let month = c.month, let day = c.day else { return "" }
        return "\(year)-\(String(format: "%02d", month))-\(String(format: "%02d", day))"
    }
}

// MARK: - Notion

struct NotionPage: Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let lastEditedAt: Date
    let url: String

    var timeAgo: String {
        let diff = Date().timeIntervalSince(lastEditedAt)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Chat

enum ChatRole { case user, assistant }

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    var content: String
}
