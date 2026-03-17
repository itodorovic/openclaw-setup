variable "do_token" {
  description = "DigitalOcean API token."
  type        = string
  sensitive   = true
}

variable "ssh_key_path" {
  description = "Path to local SSH public key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "droplet_name" {
  description = "Droplet hostname."
  type        = string
  default     = "openclaw"
}

variable "droplet_region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "Droplet size slug (2 GB minimum for native OpenClaw)."
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH. Auto-detected from deployer IP if empty."
  type        = list(string)
  default     = []
}
