terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.30"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# ── Providers ───────────────────────────────────────────────────────────────

provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── Auto-detect deployer's public IP ────────────────────────────────────────

data "http" "my_ip" {
  url = "https://api.ipify.org"
}

locals {
  ssh_cidrs           = length(var.allowed_ssh_cidrs) > 0 ? var.allowed_ssh_cidrs : ["${chomp(data.http.my_ip.response_body)}/32"]
  access_emails       = distinct(concat(var.allowed_emails, var.email_forward_to != "" ? [var.email_forward_to] : []))
  ssh_private_key_path = replace(var.ssh_key_path, ".pub", "")

  agent_team_input = length(var.agent_team) > 0 ? var.agent_team : [{
    id      = "main"
    default = true
    name    = "Main"
    model   = var.openclaw_model
  }]

  agent_team_has_default = length([for agent in local.agent_team_input : agent.id if try(agent.default, false)]) > 0

  agent_team = [
    for idx, agent in local.agent_team_input : {
      id                       = agent.id
      default                  = local.agent_team_has_default ? try(agent.default, false) : idx == 0
      name                     = try(agent.name, title(replace(agent.id, "-", " ")))
      workspace                = try(agent.workspace, null) != null ? agent.workspace : (agent.id == "main" ? "~/.openclaw/workspace" : "~/.openclaw/workspace-${agent.id}")
      agent_dir                = try(agent.agent_dir, null) != null ? agent.agent_dir : "~/.openclaw/agents/${agent.id}/agent"
      model                    = try(agent.model, var.openclaw_model)
      model_fallbacks          = try(agent.model_fallbacks, [])
      tool_profile             = try(agent.tool_profile, "coding")
      tools_allow              = try(agent.tools_allow, [])
      tools_deny               = try(agent.tools_deny, [])
      sandbox_mode             = try(agent.sandbox_mode, "off")
      sandbox_scope            = try(agent.sandbox_scope, "agent")
      sandbox_workspace_access = try(agent.sandbox_workspace_access, "none")
      identity_name            = try(agent.identity_name, null)
      identity_theme           = try(agent.identity_theme, null)
      identity_emoji           = try(agent.identity_emoji, null)
      persona                  = try(agent.persona, null)
      bindings                 = try(agent.bindings, [])
    }
  ]

  openclaw_seed_agents = [
    for agent in local.agent_team : merge(
      {
        id       = agent.id
        default  = agent.default
        name     = agent.name
        workspace = agent.workspace
        agentDir = agent.agent_dir
        model    = length(agent.model_fallbacks) > 0 ? {
          primary   = agent.model
          fallbacks = agent.model_fallbacks
        } : agent.model
        tools = merge(
          { profile = agent.tool_profile },
          length(agent.tools_allow) > 0 ? { allow = agent.tools_allow } : {},
          length(agent.tools_deny) > 0 ? { deny = agent.tools_deny } : {}
        )
      },
      agent.sandbox_mode != "off" ? {
        sandbox = {
          mode            = agent.sandbox_mode
          scope           = agent.sandbox_scope
          workspaceAccess = agent.sandbox_workspace_access
        }
      } : {},
      (
        agent.identity_name != null || agent.identity_theme != null || agent.identity_emoji != null
      ) ? {
        identity = merge(
          agent.identity_name != null ? { name = agent.identity_name } : {},
          agent.identity_theme != null ? { theme = agent.identity_theme } : {},
          agent.identity_emoji != null ? { emoji = agent.identity_emoji } : {}
        )
      } : {}
    )
  ]

  openclaw_seed_bindings = flatten([
    for agent in local.agent_team : [
      for binding in agent.bindings : {
        agentId = agent.id
        match = merge(
          { channel = binding.channel },
          try(binding.account_id, null) != null ? { accountId = binding.account_id } : {},
          try(binding.peer_kind, null) != null && try(binding.peer_id, null) != null ? {
            peer = {
              kind = binding.peer_kind
              id   = binding.peer_id
            }
          } : {}
        )
      }
    ]
  ])

  openclaw_seed_config = {
    agents = {
      defaults = {
        model = {
          primary = var.openclaw_model
        }
        workspace = "~/.openclaw/workspace"
        memorySearch = {
          enabled = false
        }
      }
      list = local.openclaw_seed_agents
    }
    bindings = local.openclaw_seed_bindings
    gateway = {
      bind = "lan"
      auth = {
        mode = "token"
        rateLimit = {
          maxAttempts = 10
          windowMs    = 60000
          lockoutMs   = 300000
        }
      }
      mode = "local"
      controlUi = {
        allowedOrigins = ["https://${var.domain_name}"]
      }
      trustedProxies = ["172.16.0.0/12", "10.0.0.0/8"]
    }
    tools = merge(
      {
        profile = "coding"
      },
      var.enable_agent_to_agent ? {
        agentToAgent = {
          enabled = true
          allow   = [for agent in local.agent_team : agent.id]
        }
      } : {}
    )
    session = {
      dmScope = "per-channel-peer"
    }
    browser = {
      enabled = var.browser_enabled
    }
    discovery = {
      mdns = { mode = "off" }
    }
    logging = {
      redactSensitive = "tools"
    }
  }

  agent_team_seed = {
    agents = local.agent_team
  }
}

# ── Random Secrets ──────────────────────────────────────────────────────────

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "random_password" "gateway_token" {
  length  = 48
  special = false
}

resource "random_password" "backup_passphrase" {
  length  = 32
  special = false
}
