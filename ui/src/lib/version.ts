// Display only; comparisons and requests keep the original package identity.
export function displayVersion(value?: string | null) {
  return value ? value.replace(/^v/, '').replace(/-r\d+$/, '') : '版本未提供';
}
