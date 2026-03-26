# Code

- Ensure the code can run under macOS, Debian, and Synology DSM
- Do not use any dependency that is not commonly available by default on these platforms (e.g. no `jq` for JSON parsing), with the exception of the "Git server" package on Synology DSM which provides `git` command line tools

# Commit Messages

- Make small, focused, single responsibility commits with descriptive messages.
- Do not use Conventional Commits style messages.
