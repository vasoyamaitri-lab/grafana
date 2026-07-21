# Automated Security Fixes

6 fixes applied:

1. **Dockerfile** - Add USER directive to run containers as non-root user
2. **Dockerfile** - Use more restrictive permissions like 755 for directories and 644 for files
3. **Dockerfile** - Ensure all apk add commands use --no-cache flag
4. **Dockerfile** - Minimize installed packages and ensure cache cleanup
5. **Dockerfile** - Complete the Dockerfile with proper USER directives and security configurations
6. **Dockerfile** - Pin to specific version with digest or full version number
