import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const checker = resolve("tools/check_records.py");

function fixture(t: test.TestContext) {
  const root = mkdtempSync(join(tmpdir(), "relay-records-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" };
  const git = (...args: string[]) => execFileSync("git", ["-C", root, ...args], { env, stdio: "pipe" });
  const write = (path: string, text: string) => writeFileSync(join(root, path), text);
  git("init", "--quiet");
  write(".gitignore", "/tmp/\n");
  write("README.md", "[Target](target.md)\n");
  write("target.md", "# Target\n");
  git("add", ".");
  return {
    root, git, write,
    check(staged = true) {
      const result = spawnSync("python3", [checker, "--root", root, ...(staged ? ["--staged"] : [])], {
        encoding: "utf8", env,
      });
      assert.ifError(result.error);
      return result;
    },
  };
}

test("records checks use staged document content even when working edits disagree", (t) => {
  const { git, write, check } = fixture(t);
  write("README.md", "[Missing](missing.md)\n");
  assert.equal(check().status, 0);
  assert.equal(check(false).status, 1);

  git("add", "README.md");
  write("README.md", "[Target](target.md)\n");
  const staged = check();
  assert.equal(staged.status, 1);
  assert.match(staged.stdout, /broken link missing.md/);
  assert.equal(check(false).status, 0);
});

test("staged link targets and scratch ignores do not depend on the working tree", (t) => {
  const { root, git, write, check } = fixture(t);
  unlinkSync(join(root, "target.md"));
  write(".gitignore", "");
  assert.equal(check().status, 0);

  git("add", ".gitignore");
  write(".gitignore", "/tmp/\n");
  const ignored = check();
  assert.equal(ignored.status, 1);
  assert.match(ignored.stdout, /does not ignore tmp/);

  git("add", ".gitignore");
  write("README.md", "[New target](new.md)\n");
  write("new.md", "# Not staged\n");
  git("add", "README.md");
  const target = check();
  assert.equal(target.status, 1);
  assert.match(target.stdout, /broken link new.md/);
  assert.equal(check(false).status, 0);
});
