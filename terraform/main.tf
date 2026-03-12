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
  ssh_cidrs      = length(var.allowed_ssh_cidrs) > 0 ? var.allowed_ssh_cidrs : ["${chomp(data.http.my_ip.response_body)}/32"]
  access_emails  = distinct(concat(var.allowed_emails, var.email_forward_to != "" ? [var.email_forward_to] : []))
  ssh_private_key_path = replace(var.ssh_key_path, ".pub", "")
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
