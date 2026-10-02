import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import request from "supertest";
import { afterEach, describe, expect, it } from "vitest";
import { bootstrapStore } from "../src/bootstrap.js";
import { DEFAULT_MANAGED_TEMPLATES_DIR, loadManagedTemplates } from "../src/templates/managed.js";
import { AUTH, setup, silentLogger } from "./helpers.js";

const FIXTURES = fileURLToPath(new URL("./fixtures/managed/", import.meta.url));
const SERVER_ROOT = fileURLToPath(new URL("../", import.meta.url));

function captureLogger() {
  const info: string[] = [];
  const error: string[] = [];
  return { logger: { info: (m: string) => info.push(m), error: (m: string) => error.push(m) }, info, error };
}

const tempDirs: string[] = [];
afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function copyFixtures(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "localocr-managed-"));
  tempDirs.push(dir);
  await cp(FIXTURES, dir, { recursive: true });
  return dir;
}

describe("repo-managed templates", () => {
  it("creates managed templates on startup and skips invalid files", async () => {
    const { logger, info, error } = captureLogger();
    const { app, store } = await setup();
    const { managed } = await bootstrapStore(store, { logger, managedTemplatesDir: FIXTURES });

    expect(managed).toMatchObject({ created: ["customs_air", "menu"], updated: [], unchanged: [] });
    expect(managed!.skipped.map((s) => s.file)).toEqual(["bad_rules.json", "broken.json"]);
    expect(error).toHaveLength(2);
    expect(error[0]).toMatch(/bad_rules\.json.*rules\.0\.set/);
    expect(error[1]).toMatch(/broken\.json.*invalid JSON/);
    expect(info.join("\n")).toMatch(/created customs_air, menu; updated -; unchanged -; skipped 2 invalid file/);

    const list = await request(app).get("/v1/templates").set(AUTH).expect(200);
    expect(list.body.items.map((t: { id: string }) => t.id)).toEqual([
      "receipt", "business_card", "event", "document", "customs_air", "menu",
    ]);

    // Stored exactly as written in the file, key order included.
    const file = JSON.parse(await readFile(path.join(FIXTURES, "customs_air.json"), "utf8"));
    const res = await request(app).get("/v1/templates/customs_air").set(AUTH).expect(200);
    expect(res.text).toContain(`"sample":${JSON.stringify(file.sample)}`);
    expect(res.text).toContain(`"rules":${JSON.stringify(file.rules)}`);
    expect(res.body).toMatchObject({ name: file.name, keywords: file.keywords, instructions: file.instructions, version: 1 });

    const menu = await request(app).get("/v1/templates/menu").set(AUTH).expect(200);
    expect(menu.body).toMatchObject({ keywords: [], instructions: null, rules: [], version: 1 });
  });

  it("leaves unchanged templates alone and repairs drifted copies", async () => {
    const { app, store } = await setup();
    await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: FIXTURES });
    const again = await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: FIXTURES });
    expect(again.managed).toMatchObject({ created: [], updated: [], unchanged: ["customs_air", "menu"] });
    expect((await request(app).get("/v1/templates/menu").set(AUTH)).body.version).toBe(1);

    // Someone edits the managed template through the API: the repo file wins on next startup.
    await request(app)
      .put("/v1/templates/customs_air")
      .set(AUTH)
      .send({ name: "改過", description: "改過", sample: { x: 1 } })
      .expect(200);
    const repaired = await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: FIXTURES });
    expect(repaired.managed).toMatchObject({ created: [], updated: ["customs_air"], unchanged: ["menu"] });
    const res = await request(app).get("/v1/templates/customs_air").set(AUTH).expect(200);
    expect(res.body).toMatchObject({ name: "空運報關單（測試）", version: 3 });
    expect(res.body.rules).toHaveLength(5);
  });

  it("updates when a repo file changes, including key order and rules", async () => {
    const dir = await copyFixtures();
    const { app, store } = await setup();
    await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: dir });

    const menuPath = path.join(dir, "menu.json");
    const menu = JSON.parse(await readFile(menuPath, "utf8"));
    menu.sample = { dishes: menu.sample.dishes, shop: menu.sample.shop }; // same content, new key order
    await writeFile(menuPath, JSON.stringify(menu));
    const reordered = await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: dir });
    expect(reordered.managed).toMatchObject({ updated: ["menu"], unchanged: ["customs_air"] });
    const got = await request(app).get("/v1/templates/menu").set(AUTH).expect(200);
    expect(Object.keys(got.body.sample)).toEqual(["dishes", "shop"]);
    expect(got.body.version).toBe(2);

    const airPath = path.join(dir, "customs_air.json");
    const air = JSON.parse(await readFile(airPath, "utf8"));
    air.rules[0].round = 3;
    await writeFile(airPath, JSON.stringify(air));
    const ruleChange = await bootstrapStore(store, { logger: silentLogger, managedTemplatesDir: dir });
    expect(ruleChange.managed).toMatchObject({ updated: ["customs_air"], unchanged: ["menu"] });
    expect((await request(app).get("/v1/templates/customs_air").set(AUTH)).body.rules[0].round).toBe(3);
  });

  it("skips duplicate ids and tolerates a missing directory", async () => {
    const dir = await copyFixtures();
    await writeFile(path.join(dir, "zz_menu_copy.json"), await readFile(path.join(FIXTURES, "menu.json")));
    const { logger, error } = captureLogger();
    const loaded = await loadManagedTemplates(dir, logger);
    expect(loaded.templates.map((t) => t.id)).toEqual(["customs_air", "menu"]);
    expect(loaded.skipped.map((s) => s.file)).toEqual(["bad_rules.json", "broken.json", "zz_menu_copy.json"]);
    expect(error[2]).toMatch(/duplicate id "menu".*menu\.json/);

    const { store } = await setup();
    const missing = captureLogger();
    const result = await bootstrapStore(store, { logger: missing.logger, managedTemplatesDir: path.join(dir, "nope") });
    expect(result.managed).toEqual({ created: [], updated: [], unchanged: [], skipped: [] });
    expect(missing.error).toEqual([]);
  });

  it("resolves the default directory to server/templates/managed", () => {
    expect(path.resolve(DEFAULT_MANAGED_TEMPLATES_DIR)).toBe(path.resolve(SERVER_ROOT, "templates", "managed"));
  });

  it("every repo-managed template file is valid", async () => {
    const { logger, error } = captureLogger();
    const { skipped } = await loadManagedTemplates(DEFAULT_MANAGED_TEMPLATES_DIR, logger);
    expect(skipped).toEqual([]);
    expect(error).toEqual([]);
  });
});
