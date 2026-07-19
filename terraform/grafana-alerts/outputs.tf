output "security_detections_folder_id" {
  description = "Numeric Grafana folder ID for 'Security Detections' — paste into homelab-detections' config/config.yml as integration.folder_id (that field is the numeric ID, not the UID)."
  value       = grafana_folder.security_detections.id
}

output "security_detections_folder_uid" {
  description = "UID of the 'Security Detections' folder, for reference/linking."
  value       = grafana_folder.security_detections.uid
}
