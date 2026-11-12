# GitHub access tokens for the KI VM

Use two **fine-grained** personal access tokens with different scopes and lifetimes. Do not use classic tokens: their scopes apply to every repository you can access.

| Token | Used by | Where it lives |
|---|---|---|
| Setup token | `ssh <userfacing> create <repo> <token>` to clone the setup repo | Typed at the prompt and passed once to `create`. Not stored by `startKIVM.sh`. |
| Work token | `gh`, `git push`/`pull`, Copilot CLI on the VM | `~/.config/ki/gh_token` on the VM (mode `600`), exported as `GH_TOKEN` |

If the setup repo is public, leave the setup token blank.

## Creating the tokens

GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.

### Setup token
- **Resource owner:** the owner of the setup repo.
- **Expiration:** 7 days (create a new one when you need to recreate a VM).
- **Repository access:** *Only select repositories* → the setup repo only.
- **Repository permissions:** `Contents: Read-only` (`Metadata: Read-only` is added automatically).
- Nothing else.

### Work token
- **Resource owner:** your user, or the organisation that owns the repos you will work on. Organisations may require an admin to approve fine-grained tokens.
- **Expiration:** 30–90 days.
- **Repository access:** *Only select repositories* → the repos you want the agents to work on.
- **Repository permissions:**
  - `Contents: Read and write`
  - `Pull requests: Read and write`
  - `Issues: Read and write` (only if needed)
- **Account permissions:** `Copilot Requests` (required by the Copilot CLI).

## Practices

- **Agents can read the work token.** Anything running in the VM shell, including Copilot and Claude Code, sees `GH_TOKEN`. Only grant access to repos you are comfortable letting an agent push to.
- **Never put a token on a command line, in a repo, or in chat/agent prompts.** `startKIVM.sh` reads tokens with a hidden prompt and sends the work token to the VM over SSH stdin.
- **The setup token is the exception:** the `create` interface takes it as an argument, so it may end up in shell history or logs on the user-facing host. This is why it is read-only, limited to one repo and short-lived.
- **Use short expirations** and recreate tokens rather than extending them.
- **Revoke immediately** if a token leaks or the VM is compromised: same settings page → token → *Delete*. Destroying the VM alone does not invalidate the token.
- Tokens can also be passed via the `KI_SETUP_TOKEN` / `KI_WORK_TOKEN` environment variables, e.g. from a password manager CLI. Avoid exporting them in your laptop's shell rc files.

## Replacing the work token

```bash
./startKIVM.sh --new-token
```

Open shells on the VM keep the old `GH_TOKEN`; start a new shell (or `source ~/.config/ki/env.sh`) afterwards.
