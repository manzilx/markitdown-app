export interface EngineInfo {
  id: string;
  label: string;
  description: string;
  badge: string;
  available: boolean;
  reason?: string | null;
}

export interface EnginesResponse {
  engines: EngineInfo[];
  default_engine: string;
}

export interface ConvertResponse {
  filename: string;
  engine: string;
  markdown: string;
  title: string;
}
