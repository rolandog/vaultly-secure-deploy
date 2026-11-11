# rotation demo writer; no access to sys/, auth/ or policies
path "secret/data/vaultly/*" {
  capabilities = ["create", "update", "read"]
}

path "secret/metadata/vaultly/*" {
  capabilities = ["read", "list"]
}
