# The bpg provider reads PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN,
# prepared at container start from the operator's configuration and token file.
provider "proxmox" {}

# Add explicitly owned resources here; do not manage pre-existing resources
# with this state unless you have imported them first.
