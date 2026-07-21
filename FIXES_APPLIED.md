# Automated Security Fixes

5 fixes applied:

1. **Dockerfile** - Add USER directive with non-root user in build stages where applicable
2. **Dockerfile** - Use more restrictive permissions like 755 for directories and 644 for files
3. **Dockerfile** - Pin images to specific SHA256 digests for reproducible builds
4. **Dockerfile** - Add validation or use a fixed path pattern for the tarball
5. **Dockerfile** - Complete the Dockerfile with proper USER directive and security configurations
