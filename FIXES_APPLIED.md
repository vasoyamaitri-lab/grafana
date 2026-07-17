# Automated Security Fixes

5 fixes applied:

1. **Dockerfile** - Add a non-root user and switch to it for build operations
2. **Dockerfile** - Add a non-root user and switch to it for build operations
3. **Dockerfile** - Use more restrictive permissions (755 for directories, 644 for files)
4. **Dockerfile** - Add validation or use a fixed path pattern for the tarball
5. **Dockerfile** - Specify uid and gid for cache mounts
