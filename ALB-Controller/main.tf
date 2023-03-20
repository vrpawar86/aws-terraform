//------------------------------------------------------------------------------------------
#Fetch EKS OIDC Data
data "aws_eks_cluster" "oidc_url" {
  name = var.cluster_name
}

output "oidc_provider_url" {
  value = data.aws_eks_cluster.oidc_url.identity.0.oidc.0.issuer
}

data "aws_eks_cluster" "oidc_arn" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "my_provider" {
  url = data.aws_eks_cluster.oidc_arn.identity.0.oidc.0.issuer
}

output "eks_oidc_provider_arn" {
  value = data.aws_iam_openid_connect_provider.my_provider.arn
}
//---
#create ALB controller Policy
resource "aws_iam_policy" "alb_controller_policy" {
  name        = "${var.project_name}-AWSLoadBalancerControllerIAMPolicy"
  path        = "/"
  description = "Policy for ALB Controller"
  tags = {
    Name = "${var.project_name}-AWSLoadBalancerControllerIAMPolicy"
  }
  policy = file("./alb_controllerpolicy.json")
}
//---
#ALB Controller Role
resource "aws_iam_role" "eks_alb_controller_role" {
  name               = "${var.project_name}-AmazonEKSLoadBalancerControllerRole"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_alb_iam_role_policy.json
  tags = {
    "Name" = "${var.project_name}-AmazonEKSLoadBalancerControllerRole"
  }
}

data "aws_iam_policy_document" "eks_cluster_alb_iam_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.oidc_url.identity.0.oidc.0.issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.oidc_url.identity.0.oidc.0.issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    principals {
      identifiers = [data.aws_iam_openid_connect_provider.my_provider.arn]
      type        = "Federated"
    }
  }
}

//------------------------------------------------------------------------------------------
#Attach ALB CONTROLLER Policy to Above Role
resource "aws_iam_role_policy_attachment" "attach_ebs_csi_policy" {
  role       = aws_iam_role.eks_alb_controller_role.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn

  depends_on = [
    aws_iam_role.eks_alb_controller_role,
    aws_iam_policy.alb_controller_policy
  ]
}
//------------------------------------------------------------------------------------------
#Create Service Account for aws-load-balancer-controller
resource "kubernetes_service_account" "aws-load-balancer-controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/name" = "aws-load-balancer-controller"
      "app.kubernetes.io/component" ="controller"

    }

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.eks_alb_controller_role.arn
    }
  }
}

//------------------------------------------------------------------------------------------
#Deploying aws_load-balancer-controller in cluster

resource "helm_release" "aws_load-balancer-controller" {
  name = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  depends_on = [
    kubernetes_service_account.aws-load-balancer-controller
  ]

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }  
  set {
    name  = "image.repository"
    value = format("602401143452.dkr.ecr.%s.amazonaws.com/amazon/aws-load-balancer-controller", var.region)
  }
  set {
    name  = "image.tag"
    value = "v2.4.7"
  }
}
