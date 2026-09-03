output "project_name" {
  description = "Cloudflare Pages project name (used by wrangler)"
  value       = cloudflare_pages_project.this.name
}

output "pages_url" {
  description = "Cloudflare Pages URL"
  value       = "${cloudflare_pages_project.this.name}.pages.dev"
}
