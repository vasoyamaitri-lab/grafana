# Automated Security Fixes

5 fixes applied:

1. **Dockerfile** - Add a non-root user and switch to it for build operations
2. **Dockerfile** - Add a non-root user and switch to it for build operations
3. **Dockerfile** - Use more restrictive permissions (755 for directories, 644 for files)
4. **Dockerfile** - Use a non-root user's cache directory with proper ownership
5. **Dockerfile** - Add HEALTHCHECK instruction to monitor container health
