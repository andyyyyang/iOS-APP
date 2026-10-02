import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import request from "supertest";
import { afterEach, describe, expect, it } from "vitest";
import { API_KEY, FakeClassifier, randomScanId, scanBody, setup, AUTH } from "./helpers.js";

const servers: Server[] = [];
const clients: Client[] = [];

afterEach(async () => {
  await Promise.all(clients.splice(0).map((client) => client.close()));
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
});

async function connect(options: Parameters<typeof setup>[0] = {}, headers: Record<string, string> = AUTH) {
  const { app } = await setup(options);
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address() as AddressInfo;
  const client = new Client({ name: "test-client", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`), {
    requestInit: { headers },
  });
  await client.connect(transport);
  clients.push(client);
  return { app, client };
}

const parse = (result: Awaited<ReturnType<Client["callTool"]>>) => {
  const content = result.content as { type: string; text: string }[];
  return JSON.parse(content[0]!.text);
};

describe("MCP /mcp", () => {
  it("lists the 9 tools", async () => {
    const { client } = await connect();
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual(
      [
        "classify_text",
        "delete_template",
        "get_scan",
        "get_template",
        "list_scans",
        "list_templates",
        "update_scan_data",
        "upsert_template",
        "validate_data",
      ].sort(),
    );
    const upsert = tools.find((t) => t.name === "upsert_template")!;
    expect(upsert.inputSchema.required).toEqual(expect.arrayContaining(["id", "name", "description", "sample"]));
  });

  it("calls list_templates, upsert_template and get_template", async () => {
    const { client } = await connect();
    const list = await client.callTool({ name: "list_templates", arguments: {} });
    expect(list.isError).toBeFalsy();
    expect(parse(list).items.map((t: { id: string }) => t.id)).toEqual(["receipt", "business_card", "event", "document"]);

    const upsert = await client.callTool({
      name: "upsert_template",
      arguments: {
        id: "wine_label",
        name: "酒標",
        description: "葡萄酒酒標",
        sample: { winery: "酒莊", vintage: 2020, grapes: ["Merlot"] },
        keywords: ["酒莊"],
      },
    });
    expect(upsert.isError).toBeFalsy();
    expect(parse(upsert)).toMatchObject({ id: "wine_label", version: 1, keywords: ["酒莊"] });
    const content = upsert.content as { text: string }[];
    expect(content[0]!.text).toContain("\n  "); // pretty JSON

    const get = await client.callTool({ name: "get_template", arguments: { id: "wine_label" } });
    const template = parse(get);
    expect(Object.keys(template.sample)).toEqual(["winery", "vintage", "grapes"]);
    expect(template.name).toBe("酒標");
  });

  it("returns isError results for failures", async () => {
    const { client } = await connect();
    const missing = await client.callTool({ name: "get_template", arguments: { id: "missing" } });
    expect(missing.isError).toBe(true);
    expect(parse(missing).error.code).toBe("not_found");

    const classify = await client.callTool({ name: "classify_text", arguments: { text: "hello" } });
    expect(classify.isError).toBe(true);
    expect(parse(classify).error.code).toBe("jev_not_configured");
  });

  it("works with scans, validation and classification", async () => {
    const { app, client } = await connect({ classifier: new FakeClassifier() });
    const id = randomScanId();
    await request(app).put(`/v1/scans/${id}`).set(AUTH).send(scanBody({ data: null })).expect(201);

    const list = parse(await client.callTool({ name: "list_scans", arguments: { query: "鮮乳" } }));
    expect(list.items).toHaveLength(1);
    expect(list.items[0]).toMatchObject({ id, title: "全聯福利中心", hasData: false });

    const data = { title: "t", date: null, summary: "s", keyPoints: [], people: [], actionItems: [] };
    const validation = parse(await client.callTool({ name: "validate_data", arguments: { templateId: "document", data } }));
    expect(validation).toEqual({ valid: true, issues: [] });

    const updated = parse(
      await client.callTool({ name: "update_scan_data", arguments: { id: id.toLowerCase(), data, templateId: "document" } }),
    );
    expect(updated).toMatchObject({ id, templateId: "document", data });

    const scan = parse(await client.callTool({ name: "get_scan", arguments: { id } }));
    expect(scan.text).toContain("鮮乳");

    const classified = parse(
      await client.callTool({ name: "classify_text", arguments: { text: "x", templateIds: ["event", "document"] } }),
    );
    expect(classified.templateId).toBe("event");

    const deleted = parse(await client.callTool({ name: "delete_template", arguments: { id: "event" } }));
    expect(deleted).toEqual({ deleted: true, id: "event" });
  });

  it("requires auth", async () => {
    await expect(connect({}, {})).rejects.toThrow();
    await expect(connect({}, { Authorization: "Bearer wrong" })).rejects.toThrow();
    const { client } = await connect({}, { Authorization: `Bearer ${API_KEY}` });
    expect((await client.listTools()).tools).toHaveLength(9);
  });

  it("rejects GET and DELETE in stateless mode", async () => {
    const { app } = await setup();
    await request(app).get("/mcp").set(AUTH).expect(405);
    await request(app).delete("/mcp").set(AUTH).expect(405);
  });
});
