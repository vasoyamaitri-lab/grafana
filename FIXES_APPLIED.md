# Automated Security Fixes

6 fixes applied:

1. **Dockerfile** - Add a non-root user for the build process where possible
2. **Dockerfile** - The go-builder cache mount uses /root/.cache which requires root, but this is acceptable for build stages
3. **Dockerfile** - Use more restrictive permissions like 755 for directories and 644 for files
4. **Dockerfile** - Ensure regular updates to base images and consider using image digests for immutability
5. **Dockerfile** - Pin to a specific version like node:24.0.0-alpine3.21
6. **Dockerfile** - Use a valid and current Go version like 1.23.5-alpine
