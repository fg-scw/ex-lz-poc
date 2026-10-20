terraform {
  required_version = ">= 1.10"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.86"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
