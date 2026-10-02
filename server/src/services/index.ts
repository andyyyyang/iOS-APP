import type { Classifier } from "../classifier/types.js";
import type { Store } from "../store/types.js";
import { ClassifyService } from "./classify.js";
import { ScanService } from "./scans.js";
import { TemplateService } from "./templates.js";
import { ValidateService } from "./validate.js";

/** Business logic shared by the REST routes and the MCP tools. */
export interface Services {
  store: Store;
  scans: ScanService;
  templates: TemplateService;
  classify: ClassifyService;
  validate: ValidateService;
}

export function createServices({ store, classifier }: { store: Store; classifier: Classifier | null }): Services {
  return {
    store,
    scans: new ScanService(store),
    templates: new TemplateService(store),
    classify: new ClassifyService(store, classifier),
    validate: new ValidateService(store),
  };
}

export { ClassifyService, ScanService, TemplateService, ValidateService };
