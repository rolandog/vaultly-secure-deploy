data "aws_caller_identity" "current" {}

# fails early if the cluster does not exist
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  role_name = "${var.cluster_name}-openbao-seal"
}

module "openbao_role" {
  source = "../modules/pod-identity-role"

  name            = local.role_name
  namespace       = var.openbao_namespace
  service_account = var.openbao_service_account
}

data "aws_iam_policy_document" "seal_use" {
  statement {
    sid       = "SealCrypto"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.seal.arn]
  }
}

resource "aws_iam_role_policy" "seal_use" {
  name   = "seal-use"
  role   = module.openbao_role.role_name
  policy = data.aws_iam_policy_document.seal_use.json
}

data "aws_iam_policy_document" "seal_key" {
  #checkov:skip=CKV_AWS_356:key policy Resource "*" means this KMS key; the only valid value
  #checkov:skip=CKV_AWS_109:PutKeyPolicy for the account principal is the intentional key-admin duty; crypto actions are excluded
  #checkov:skip=CKV_AWS_111:administrative key actions only, no Encrypt, Decrypt or GenerateDataKey; Resource "*" is this key
  statement {
    sid    = "KeyAdminNoCrypto"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    # explicit list: no Encrypt/Decrypt/GenerateDataKey, and no kms:Create* (it includes CreateGrant)
    actions = [
      "kms:CreateAlias",
      "kms:UpdateAlias",
      "kms:DeleteAlias",
      "kms:DescribeKey",
      "kms:EnableKey",
      "kms:DisableKey",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:GetKeyRotationStatus",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:ListKeyPolicies",
      "kms:ListResourceTags",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:UpdateKeyDescription",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "OpenBaoSealOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [module.openbao_role.role_arn]
    }

    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "seal" {
  description             = "rg-vaultly OpenBao auto-unseal key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.seal_key.json
}

resource "aws_kms_alias" "seal" {
  name          = "alias/${var.cluster_name}-openbao-seal"
  target_key_id = aws_kms_key.seal.key_id
}

resource "aws_eks_pod_identity_association" "openbao" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = var.openbao_namespace
  service_account = var.openbao_service_account
  role_arn        = module.openbao_role.role_arn
}
