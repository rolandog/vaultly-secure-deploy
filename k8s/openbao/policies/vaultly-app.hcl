# rotation demo credential: read only, new values arrive as KV v2 versions written by the operator
path "secret/data/vaultly/database" {
  capabilities = ["read"]
}

# secrets api of the app (PUT, GET, DELETE /api/v1/secrets/<path>): vault_client.py passes <path> unchanged; app-config/ is the README example prefix
path "secret/data/app-config/*" {
  capabilities = ["create", "update", "read"]
}

# delete_metadata_and_all_versions sends DELETE to the metadata path
path "secret/metadata/app-config/*" {
  capabilities = ["delete"]
}
