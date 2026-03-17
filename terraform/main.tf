terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.30"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# ── Auto-detect deployer's public IP ────────────────────────────────────────

data "http" "my_ip" {
  url = "https://api.ipify.org"
}

locals {
  ssh_cidrs          = length(var.allowed_ssh_cidrs) > 0 ? var.allowed_ssh_cidrs : ["${chomp(data.http.my_ip.response_body)}/32"]
  ssh_private_key_path = replace(var.ssh_key_path, ".pub", "")
}
