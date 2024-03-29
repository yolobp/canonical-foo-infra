# This bucket must be created separately in the org infra level in the admin
# project.
terraform {
  backend "gcs" {
    # Bad name! Should be 'my-org-infra-tf'.
    bucket = "canonical-foo-tf"
    prefix = "common"
  }
}

# Create environment projects.
#
# resource "google_project" "env_project" {
#   for_each   = toset(var.environments)
#   name       = "canonical-foo-${each.key}"
#   project_id = "canonical-foo-${each.key}"
#   org_id     = "1234567"
# }

#################### GCS bucketr for product infra state ####################

resource "google_storage_bucket" "product_infra_state_bucket" {
  project                     = var.project_id
  name                        = "canonical-foo-infra-tf"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}

#################### Enable API in admin project #######################

resource "google_project_service" "serviceusage" {
  project            = var.project_id
  service            = "serviceusage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "services" {
  project = var.project_id
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudkms.googleapis.com",
    "clouddeploy.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false

  depends_on = [
    google_project_service.serviceusage,
  ]
}

#################### Artifact Registry dev and rel #######################

resource "google_artifact_registry_repository" "image_registry" {
  provider = google-beta

  location      = var.artifact_registry_location
  project       = var.project_id
  repository_id = "rel-images"
  description   = "Container Registry for the images."
  format        = "DOCKER"
  depends_on = [
    google_project_service.services["artifactregistry.googleapis.com"],
  ]
}

resource "google_artifact_registry_repository" "image_registry_dev" {
  provider = google-beta

  location      = var.artifact_registry_location
  project       = var.project_id
  repository_id = "dev-images"
  description   = "Container Registry for the images."
  format        = "DOCKER"
  depends_on = [
    google_project_service.services["artifactregistry.googleapis.com"],
  ]
}

#################### Service accounts and WIF #######################
# One for admin - previleged. One for CI - no permission by default.

resource "google_service_account" "gh-access-admin" {
  project      = var.project_id
  account_id   = "canonical-foo-admin"
  display_name = "GitHub Access Account"
}

resource "google_storage_bucket_iam_member" "admin_gcs" {
  bucket = google_storage_bucket.product_infra_state_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gh-access-admin.email}"
}

resource "google_iam_workload_identity_pool" "admin_pool" {
  provider                  = google-beta
  project                   = var.project_id
  workload_identity_pool_id = "canonical-foo-admin"
  description               = "GitHub pool"
}

resource "google_iam_workload_identity_pool_provider" "admin_pool_provider" {
  provider                           = google-beta
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.admin_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "canonical-foo-admin-provider"
  display_name                       = "GitHub Admin provider"
  attribute_mapping                  = var.pool_provider_attribute_mapping
  attribute_condition                = <<EOT
  assertion.repository == 'yolobp/canonical-foo-infra' &&
  !(assertion.event_name == 'pull_request_target')
  EOT
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "external_provider_roles_infra" {
  service_account_id = google_service_account.gh-access-admin.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.admin_pool.name}/attribute.repository/yolobp/canonical-foo-infra"
}

resource "google_service_account" "gh-access-ci" {
  project      = var.project_id
  account_id   = "canonical-foo-ci"
  display_name = "GitHub Access Account"
}

resource "google_project_iam_member" "ci_sa_permission_ar" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.gh-access-ci.email}"
}

resource "google_project_iam_member" "ci_sa_permission_clouddeploy" {
  project = var.project_id
  role    = "roles/clouddeploy.operator"
  member  = "serviceAccount:${google_service_account.gh-access-ci.email}"
}

# Also needed for cloud deploy.
resource "google_project_iam_member" "ci_sa_permission_bucket" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.gh-access-ci.email}"
}

# Also needed for cloud deploy.
resource "google_project_iam_member" "ci_sa_permission_actas" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.gh-access-ci.email}"
}

# Also needed for cloud deploy.
resource "google_project_iam_member" "ci_sa_permission_run" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.gh-access-ci.email}"
}

resource "google_iam_workload_identity_pool" "ci_pool" {
  provider                  = google-beta
  project                   = var.project_id
  workload_identity_pool_id = "canonical-foo-ci"
  description               = "GitHub pool"
}

resource "google_iam_workload_identity_pool_provider" "ci_pool_provider" {
  provider                           = google-beta
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.ci_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "canonical-foo-ci-provider"
  display_name                       = "GitHub CI provider"
  attribute_mapping                  = var.pool_provider_attribute_mapping
  attribute_condition                = <<EOT
  (assertion.repository == 'yolobp/canonical-foo' || assertion.repository == 'yolobp/rel-test') &&
  !(assertion.event_name == 'pull_request_target')
  EOT
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "external_provider_roles_ci" {
  service_account_id = google_service_account.gh-access-ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.ci_pool.name}/attribute.repository/yolobp/canonical-foo"
}

resource "google_service_account_iam_member" "external_provider_roles_ci_2" {
  service_account_id = google_service_account.gh-access-ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.ci_pool.name}/attribute.repository/yolobp/rel-test"
}

#################### Admin service account permission #######################
# Owner of environment projects.

resource "google_project_iam_member" "admin_sa_permission" {
  # for_each = toset(var.environments)
  # project  = "canonical-foo-${each.key}"
  # Use a fixed value for testing.
  project = "cshou-jvs"
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.gh-access-admin.email}"
}


#################### Cloud Deploy ####################

resource "google_clouddeploy_delivery_pipeline" "primary" {
  location    = "us-central1"
  name        = "pipeline"
  description = "Pipeline for the canonical foo app"

  project = var.project_id

  serial_pipeline {
    stages {
      profiles  = ["dev"]
      target_id = "run-dev"
    }

    stages {
      profiles  = ["prod"]
      target_id = "run-prod"
    }
  }
  provider = google-beta

  depends_on = [
    google_project_service.services["clouddeploy.googleapis.com"],
  ]
}


resource "google_clouddeploy_target" "dev_target" {
  location    = "us-central1"
  name        = "run-dev"
  description = "Run dev"

  execution_configs {
    usages            = ["RENDER", "DEPLOY"]
    execution_timeout = "3600s"
  }

  project          = var.project_id
  require_approval = false

  run {
    # In reality, the project should be per-env.
    location = "projects/cshou-jvs/locations/us-west1"
  }
  provider = google-beta

  depends_on = [
    google_project_service.services["clouddeploy.googleapis.com"],
  ]
}

resource "google_clouddeploy_target" "prod_target" {
  location    = "us-central1"
  name        = "run-prod"
  description = "Run prod"

  execution_configs {
    usages            = ["RENDER", "DEPLOY"]
    execution_timeout = "3600s"
  }

  project          = var.project_id
  require_approval = true

  run {
    # In reality, the project should be per-env.
    location = "projects/cshou-jvs/locations/us-west1"
  }
  provider = google-beta

  depends_on = [
    google_project_service.services["clouddeploy.googleapis.com"],
  ]
}
