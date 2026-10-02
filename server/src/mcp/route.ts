import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { Router, type Request, type Response } from "express";
import type { Services } from "../services/index.js";
import { createMcpServer } from "./server.js";

/**
 * Stateless Streamable HTTP: every POST gets a fresh server + transport, so any instance can serve
 * any request. GET (standalone SSE) and DELETE (session end) have no meaning without sessions.
 */
export function mcpRouter(services: Services): Router {
  const router = Router();

  router.post("/", async (req, res) => {
    const server = createMcpServer(services);
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    res.on("close", () => {
      void transport.close();
      void server.close();
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      console.error("[mcp] request failed", error);
      if (!res.headersSent) {
        res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal server error" }, id: null });
      }
    }
  });

  const methodNotAllowed = (_req: Request, res: Response) => {
    res
      .status(405)
      .set("Allow", "POST")
      .json({ error: { code: "method_not_allowed", message: "Stateless MCP endpoint: use POST" } });
  };
  router.get("/", methodNotAllowed);
  router.delete("/", methodNotAllowed);

  return router;
}
