data "aws_caller_identity" "current" {}

# shared, account-wide object: read only, never managed or destroyed here
data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

locals {
  role_name  = "rg-vaultly-gha-readonly"
  sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
  subs       = [for b in var.trusted_branches : "${local.sub_prefix}:ref:refs/heads/${b}"]
}

data "aws_iam_policy_document" "trust" {
  # checkov:skip=CKV_AWS_358: the check regex rejects GitHub's immutable sub (owner@id/repo@id); trust pins two exact sub values, no wildcard (validated in variables.tf)
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subs
    }
  }
}

data "aws_iam_policy_document" "readonly" {
  statement {
    sid       = "ReadCiSecret"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ci_secret_name}"]
  }

  statement {
    sid     = "DescribeNetwork"
    effect  = "Allow"
    actions = ["ec2:DescribeVpcs", "ec2:DescribeSecurityGroups"]
    # these Describe actions do not support resource-level permissions
    resources = ["*"]
  }
}

resource "aws_iam_role" "gha_readonly" {
  name                 = local.role_name
  description          = "rg-vaultly GitHub Actions, read-only, exact-sub trust"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = contains(data.aws_iam_openid_connect_provider.github.client_id_list, "sts.amazonaws.com")
      error_message = "the shared GitHub OIDC provider lacks the sts.amazonaws.com client id; report it, do not modify it"
    }
  }
}

resource "aws_iam_role_policy" "readonly" {
  name   = "rg-vaultly-gha-readonly"
  role   = aws_iam_role.gha_readonly.id
  policy = data.aws_iam_policy_document.readonly.json
}
