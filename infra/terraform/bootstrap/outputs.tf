output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "backend_hcl_path" {
  value = abspath(local_file.backend_hcl.filename)
}
