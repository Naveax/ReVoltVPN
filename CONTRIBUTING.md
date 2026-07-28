# Contributing to ReVoltVPN

We would love for you to contribute to ReVoltVPN and help make it even better than it is today!
As a contributor, here are the guidelines we would like you to follow:

## <a name="commit"></a> Commit Message Format

*This specification is inspired by the Angular commit message format.*

#### <a name="commit-header"></a>Commit Message Header

```
<type>(<scope>): <short summary>
  │       │             │
  │       │             └─⫸ Summary in present tense. Not capitalized. No period at the end.
  │       │
  │       └─⫸ Commit Scope: app|server|xray|nginx|docs|config
  │
  └─⫸ Commit Type: build|ci|docs|feat|fix|perf|refactor|test
```

The `<type>` and `<summary>` fields are mandatory, the `(<scope>)` field is optional.

##### Type

Must be one of the following:

* **build**: Changes that affect the build system or external dependencies (example: Flutter, pub, Gradle)
* **ci**: Changes to CI configuration files and scripts
* **docs**: Documentation only changes (README, AGENTS.md, comments)
* **feat**: A new feature
* **fix**: A bug fix
* **perf**: A code change that improves performance
* **refactor**: A code change that neither fixes a bug nor adds a feature
* **test**: Adding missing tests or correcting existing tests
* **style**: Changes that do not affect the meaning of the code (formatting, whitespace)

##### Scope

The scope should be the part of the project affected:

* `app` — Flutter client (screens, components, logic)
* `server` — Python Hivemind backend
* `xray` — Xray Reality config or tunnel behavior
* `nginx` — nginx routing, SSL, auth
* `docs` — documentation files
* `config` — app_config, .gitignore, pubspec

##### Summary

Use the summary field to provide a succinct description of the change:

* use the imperative, present tense: "change" not "changed" nor "changes"
* don't capitalize the first letter
* no dot (.) at the end


#### <a name="commit-body"></a>Commit Message Body

Just as in the summary, use the imperative, present tense: "fix" not "fixed" nor "fixes".

Explain the motivation for the change in the commit message body. This commit message should explain _why_ you are making the change.
You can include a comparison of the previous behavior with the new behavior in order to illustrate the impact of the change.

#### Examples

```
feat(server): add swarm monitoring endpoint

GET /api/swarm returns sorted drone list for the TUI dashboard.
Persistent total GB saved to swarm_total.json, survives restarts.
```

```
fix(app): remove dead _isThrottled field from session timer

Field was written but never read — throttle handled by port-swap now.
Also removed unreachable 404 branch in _syncWithHivemind.
```

```
docs: update README with correct quota and Reality protocol details
```
