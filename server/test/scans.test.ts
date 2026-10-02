import request from "supertest";
import { describe, expect, it } from "vitest";
import { AUTH, randomScanId, scanBody, setup } from "./helpers.js";

describe("scans", () => {
  it("creates with PUT (canonical uppercase id) and returns the full scan", async () => {
    const { app } = await setup();
    const id = randomScanId();
    const res = await request(app).put(`/v1/scans/${id.toLowerCase()}`).set(AUTH).send(scanBody()).expect(201);
    expect(res.body).toMatchObject({
      id,
      createdAt: "2026-10-02T03:10:00.000Z",
      source: "camera",
      templateId: "receipt",
      lineCount: 3,
      averageConfidence: 0.91,
      pageCount: 1,
      device: "iPhone",
    });
    expect(res.body.data).toEqual(scanBody().data);
    expect(res.body.classification.provider).toBe("jev");
    expect(Date.parse(res.body.updatedAt)).not.toBeNaN();

    const got = await request(app).get(`/v1/scans/${id}`).set(AUTH).expect(200);
    expect(got.body).toEqual(res.body);
  });

  it("updates idempotently: updatedAt increases, createdAt is preserved", async () => {
    const { app } = await setup();
    const id = randomScanId();
    const first = await request(app).put(`/v1/scans/${id}`).set(AUTH).send(scanBody()).expect(201);
    const second = await request(app)
      .put(`/v1/scans/${id}`)
      .set(AUTH)
      .send(scanBody({ text: "updated", createdAt: "2030-01-01T00:00:00Z", updatedAt: "1999-01-01T00:00:00Z" }))
      .expect(200);
    expect(second.body.text).toBe("updated");
    expect(second.body.createdAt).toBe(first.body.createdAt);
    expect(Date.parse(second.body.updatedAt)).toBeGreaterThan(Date.parse(first.body.updatedAt));
  });

  it("validates the id and body", async () => {
    const { app } = await setup();
    await request(app).put("/v1/scans/not-a-uuid").set(AUTH).send(scanBody()).expect(400);
    await request(app).put(`/v1/scans/${randomScanId()}`).set(AUTH).send(scanBody({ source: "fax" })).expect(400);
    await request(app).put(`/v1/scans/${randomScanId()}`).set(AUTH).send({ source: "camera" }).expect(400);
    const mismatch = await request(app)
      .put(`/v1/scans/${randomScanId()}`)
      .set(AUTH)
      .send(scanBody({ id: randomScanId() }))
      .expect(400);
    expect(mismatch.body.error.code).toBe("invalid_request");
  });

  it("defaults optional fields to null", async () => {
    const { app } = await setup();
    const res = await request(app)
      .put(`/v1/scans/${randomScanId()}`)
      .set(AUTH)
      .send({ source: "pasteboard", text: "hello", createdAt: "2026-10-02T03:10:00+08:00" })
      .expect(201);
    expect(res.body).toMatchObject({
      createdAt: "2026-10-01T19:10:00.000Z",
      templateId: null,
      classification: null,
      data: null,
      lineCount: null,
      averageConfidence: null,
      pageCount: null,
      device: null,
    });
  });

  it("returns 404 for unknown scans", async () => {
    const { app } = await setup();
    const res = await request(app).get(`/v1/scans/${randomScanId()}`).set(AUTH).expect(404);
    expect(res.body.error.code).toBe("not_found");
    await request(app).patch(`/v1/scans/${randomScanId()}`).set(AUTH).send({ data: {} }).expect(404);
    await request(app).delete(`/v1/scans/${randomScanId()}`).set(AUTH).expect(404);
  });

  it("PATCHes data, templateId and classification", async () => {
    const { app } = await setup();
    const id = randomScanId();
    const created = await request(app).put(`/v1/scans/${id}`).set(AUTH).send(scanBody()).expect(201);
    const patched = await request(app)
      .patch(`/v1/scans/${id}`)
      .set(AUTH)
      .send({ data: { title: "x" }, templateId: "document" })
      .expect(200);
    expect(patched.body.data).toEqual({ title: "x" });
    expect(patched.body.templateId).toBe("document");
    expect(patched.body.text).toBe(created.body.text);
    expect(patched.body.classification).toEqual(created.body.classification);
    expect(Date.parse(patched.body.updatedAt)).toBeGreaterThan(Date.parse(created.body.updatedAt));

    const cleared = await request(app).patch(`/v1/scans/${id}`).set(AUTH).send({ classification: null }).expect(200);
    expect(cleared.body.classification).toBeNull();
    expect(cleared.body.data).toEqual({ title: "x" });

    await request(app).patch(`/v1/scans/${id}`).set(AUTH).send({}).expect(400);
  });

  it("DELETEs with 204", async () => {
    const { app } = await setup();
    const id = randomScanId();
    await request(app).put(`/v1/scans/${id}`).set(AUTH).send(scanBody()).expect(201);
    const res = await request(app).delete(`/v1/scans/${id}`).set(AUTH).expect(204);
    expect(res.text).toBe("");
    await request(app).get(`/v1/scans/${id}`).set(AUTH).expect(404);
  });

  describe("listing", () => {
    async function seed(app: Parameters<typeof request>[0], count: number) {
      const ids: string[] = [];
      for (let i = 0; i < count; i++) {
        const id = randomScanId();
        ids.push(id);
        await request(app)
          .put(`/v1/scans/${id}`)
          .set(AUTH)
          .send(
            scanBody({
              createdAt: new Date(Date.UTC(2026, 9, 1, 0, i)).toISOString(),
              text: `scan number ${i} ${i % 2 === 0 ? "Even 偶數" : "odd"}`,
              templateId: i % 3 === 0 ? "document" : "receipt",
            }),
          )
          .expect(201);
      }
      return ids;
    }

    it("defaults to newest createdAt first with limit 50", async () => {
      const { app } = await setup();
      const ids = await seed(app, 5);
      const res = await request(app).get("/v1/scans").set(AUTH).expect(200);
      expect(res.body.items.map((s: { id: string }) => s.id)).toEqual([...ids].reverse());
      expect(res.body.nextCursor).toBeNull();
    });

    it("pages the default order with nextCursor", async () => {
      const { app } = await setup();
      const ids = await seed(app, 5);
      const page1 = await request(app).get("/v1/scans").query({ limit: 2 }).set(AUTH).expect(200);
      expect(page1.body.nextCursor).toEqual(expect.any(String));
      const page2 = await request(app).get("/v1/scans").query({ limit: 2, cursor: page1.body.nextCursor }).set(AUTH);
      const page3 = await request(app).get("/v1/scans").query({ limit: 2, cursor: page2.body.nextCursor }).set(AUTH);
      expect(page3.body.nextCursor).toBeNull();
      const seen = [...page1.body.items, ...page2.body.items, ...page3.body.items].map((s: { id: string }) => s.id);
      expect(seen).toEqual([...ids].reverse());
    });

    it("filters by templateId", async () => {
      const { app } = await setup();
      const ids = await seed(app, 6);
      const res = await request(app).get("/v1/scans").query({ templateId: "document" }).set(AUTH).expect(200);
      expect(res.body.items.map((s: { id: string }) => s.id).sort()).toEqual([ids[0], ids[3]].sort());
    });

    it("searches text case-insensitively with q", async () => {
      const { app } = await setup();
      await seed(app, 6);
      const even = await request(app).get("/v1/scans").query({ q: "even" }).set(AUTH).expect(200);
      expect(even.body.items).toHaveLength(3);
      const chinese = await request(app).get("/v1/scans").query({ q: "偶數" }).set(AUTH).expect(200);
      expect(chinese.body.items).toHaveLength(3);
      const none = await request(app).get("/v1/scans").query({ q: "%" }).set(AUTH).expect(200);
      expect(none.body.items).toHaveLength(0);
      const combined = await request(app).get("/v1/scans").query({ q: "number 3", templateId: "document" }).set(AUTH);
      expect(combined.body.items).toHaveLength(1);
    });

    it("validates limit and cursor", async () => {
      const { app } = await setup();
      await request(app).get("/v1/scans").query({ limit: 0 }).set(AUTH).expect(400);
      await request(app).get("/v1/scans").query({ limit: "abc" }).set(AUTH).expect(400);
      await request(app).get("/v1/scans").query({ limit: 1000 }).set(AUTH).expect(200);
      const bad = await request(app).get("/v1/scans").query({ cursor: "garbage" }).set(AUTH).expect(400);
      expect(bad.body.error.code).toBe("invalid_cursor");
      await request(app).get("/v1/scans").query({ updatedAfter: "yesterday" }).set(AUTH).expect(400);
    });

    it("supports incremental sync via updatedAfter + cursor without duplicates or misses", async () => {
      const { app } = await setup();
      const ids = await seed(app, 7);

      const synced: { id: string; updatedAt: string }[] = [];
      let page = await request(app)
        .get("/v1/scans")
        .query({ updatedAfter: "1970-01-01T00:00:00Z", limit: 3 })
        .set(AUTH)
        .expect(200);
      synced.push(...page.body.items);
      while (page.body.nextCursor) {
        page = await request(app).get("/v1/scans").query({ cursor: page.body.nextCursor, limit: 3 }).set(AUTH).expect(200);
        synced.push(...page.body.items);
      }
      expect(synced.map((s) => s.id)).toEqual(ids); // ascending updatedAt = write order
      expect(new Set(synced.map((s) => s.id)).size).toBe(7);
      const updatedAts = synced.map((s) => Date.parse(s.updatedAt));
      expect([...updatedAts].sort((a, b) => a - b)).toEqual(updatedAts);

      // Later writes show up after the last seen updatedAt, oldest first.
      const watermark = synced.at(-1)!.updatedAt;
      await request(app).patch(`/v1/scans/${ids[2]}`).set(AUTH).send({ data: { x: 1 } }).expect(200);
      const newId = randomScanId();
      await request(app).put(`/v1/scans/${newId}`).set(AUTH).send(scanBody()).expect(201);
      const delta = await request(app).get("/v1/scans").query({ updatedAfter: watermark }).set(AUTH).expect(200);
      expect(delta.body.items.map((s: { id: string }) => s.id)).toEqual([ids[2], newId]);
      expect(delta.body.nextCursor).toBeNull();
    });

    it("keeps sync paging stable when rows change between pages", async () => {
      const { app } = await setup();
      const ids = await seed(app, 4);
      const page1 = await request(app)
        .get("/v1/scans")
        .query({ updatedAfter: "1970-01-01T00:00:00Z", limit: 2 })
        .set(AUTH);
      expect(page1.body.items.map((s: { id: string }) => s.id)).toEqual([ids[0], ids[1]]);
      // An already-synced row is modified mid-sync: it moves to the end instead of being lost.
      await request(app).patch(`/v1/scans/${ids[0]}`).set(AUTH).send({ data: null }).expect(200);
      const rest: string[] = [];
      let cursor = page1.body.nextCursor;
      while (cursor) {
        const page = await request(app).get("/v1/scans").query({ cursor, limit: 2 }).set(AUTH);
        rest.push(...page.body.items.map((s: { id: string }) => s.id));
        cursor = page.body.nextCursor;
      }
      expect(rest).toEqual([ids[2], ids[3], ids[0]]);
    });
  });
});
