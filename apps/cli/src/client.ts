import type {
  Note,
  NoteCreate,
  NoteUpdate,
  Folder,
  FolderCreate,
  Tag,
  ApiKey,
  ApiKeyCreate,
  ApiKeyWithSecret,
} from "@notekeeper/shared";
import type { CliConfig } from "./config";

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
  }
}

export class Client {
  constructor(private cfg: CliConfig) {}

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
    init?: RequestInit,
  ): Promise<T> {
    const url = `${this.cfg.endpoint.replace(/\/$/, "")}${path}`;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.cfg.api_key}`,
      ...((init?.headers as Record<string, string>) ?? {}),
    };
    let reqBody: BodyInit | undefined;
    if (body !== undefined) {
      if (body instanceof FormData) {
        reqBody = body;
      } else {
        headers["Content-Type"] = "application/json";
        reqBody = JSON.stringify(body);
      }
    }

    const res = await fetch(url, { method, headers, body: reqBody, ...init });

    if (res.status === 204) return undefined as T;

    const text = await res.text();
    let data: unknown = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = text;
      }
    }

    if (!res.ok) {
      const err = (data as { error?: { code: string; message: string; details?: unknown } })?.error;
      throw new ApiError(
        res.status,
        err?.code ?? "http_error",
        err?.message ?? `HTTP ${res.status}`,
        err?.details,
      );
    }
    return data as T;
  }

  // Notes
  listNotes(params: Record<string, string | number | boolean | undefined> = {}) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined && v !== null) qs.set(k, String(v));
    }
    const suffix = qs.toString() ? `?${qs}` : "";
    return this.request<{ notes: Note[]; next_cursor: string | null }>("GET", `/v1/notes${suffix}`);
  }
  createNote(body: NoteCreate) {
    return this.request<Note>("POST", "/v1/notes", body);
  }
  getNote(id: string) {
    return this.request<Note>("GET", `/v1/notes/${id}`);
  }
  updateNote(id: string, body: NoteUpdate) {
    return this.request<Note>("PATCH", `/v1/notes/${id}`, body);
  }
  deleteNote(id: string, hard = false) {
    return this.request<void>("DELETE", `/v1/notes/${id}${hard ? "?hard=true" : ""}`);
  }
  restoreNote(id: string) {
    return this.request<void>("POST", `/v1/notes/${id}/restore`);
  }

  // Folders
  listFolders() {
    return this.request<{ folders: Folder[] }>("GET", "/v1/folders");
  }
  createFolder(body: FolderCreate) {
    return this.request<Folder>("POST", "/v1/folders", body);
  }
  deleteFolder(id: string) {
    return this.request<void>("DELETE", `/v1/folders/${id}`);
  }

  // Tags
  listTags() {
    return this.request<{ tags: Tag[] }>("GET", "/v1/tags");
  }

  // Search
  search(q: string, limit = 25) {
    return this.request<{
      query: string;
      results: Array<{
        id: string;
        title: string;
        folder_id: string | null;
        pinned: boolean;
        updated_at: string;
        snippet: string;
        score: number;
      }>;
    }>("GET", `/v1/search?q=${encodeURIComponent(q)}&limit=${limit}`);
  }

  // API keys
  listKeys() {
    return this.request<{ keys: ApiKey[] }>("GET", "/v1/api-keys");
  }
  createKey(body: ApiKeyCreate) {
    return this.request<ApiKeyWithSecret>("POST", "/v1/api-keys", body);
  }
  revokeKey(id: string) {
    return this.request<void>("DELETE", `/v1/api-keys/${id}`);
  }

  // Attachments
  async uploadAttachment(noteId: string, file: File | Blob, filename: string) {
    const form = new FormData();
    form.append("file", file, filename);
    return this.request<{
      id: string;
      note_id: string;
      filename: string;
      content_type: string;
      size_bytes: number;
      created_at: string;
      url: string;
    }>("POST", `/v1/notes/${noteId}/attachments`, form);
  }

  // Health probe — used by `login` to verify endpoint + key before saving.
  async verify() {
    // Hitting a trivially authorized endpoint is the simplest health+auth check.
    await this.request<{ tags: Tag[] }>("GET", "/v1/tags");
    return true;
  }
}
