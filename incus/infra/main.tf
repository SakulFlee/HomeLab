terraform {
  required_version = ">= 1.6.0"

  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.2"
    }
  }
}

# Everything runs on the Incus host itself, against the local unix socket. The
# provider needs no TLS configuration for that and the process must run as
# root. Resource bodies (including every instance, volume and image) are
# generated into generated.tf.json by incus/gen-tf.sh.
provider "incus" {}
