<%@ WebHandler Language="C#" Class="ChatApi" %>
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

/// <summary>
/// API do chat.
///   GET  ?a=poll&since={ultimoId}       usuários, mensagens novas e quem está digitando
///   POST ?a=send    (to, body)           mensagem de texto
///   POST ?a=buzz    (to)                 campainha (somente 1:1)
///   POST ?a=upload  (to, file)           arquivo/imagem (máx. 5 MB)
///   POST ?a=typing  (to)                 "estou digitando"
///   GET  ?a=file&id={fileId}[&dl=1]      download do arquivo (só para participantes)
/// "to" vazio = sala geral. Todas as chamadas, exceto "file", exigem o cabeçalho
/// X-Requested-With: Comunicador (formulário de outro site não consegue enviá-lo: anti-CSRF).
/// </summary>
public class ChatApi : IHttpHandler
{
    private const int MaxBody = 2000;
    private const int PageSize = 200;
    private const int OnlineSeconds = 20;
    private const int TypingSeconds = 5;
    private const int BuzzCooldownSeconds = 15;
    private const int MaxFileBytes = 5 * 1024 * 1024;

    private const byte KindText = 0, KindBuzz = 1, KindFile = 2;

    // "Digitando" fica só em memória: é efêmero e não vale uma ida ao banco.
    private sealed class TypingInfo { public int? To; public DateTime At; }
    private static readonly ConcurrentDictionary<int, TypingInfo> Typing = new ConcurrentDictionary<int, TypingInfo>();

    public bool IsReusable { get { return true; } }

    public void ProcessRequest(HttpContext ctx)
    {
        string a = ctx.Request.QueryString["a"];
        string method = ctx.Request.HttpMethod;

        if (a == "file" && method == "GET")
        {
            ChatUser u = Auth.Current(ctx);
            if (u == null || u.MustChangePassword) { ctx.Response.StatusCode = 401; return; }
            DownloadFile(ctx, u);
            return;
        }

        ctx.Response.ContentType = "application/json";
        ctx.Response.Cache.SetCacheability(HttpCacheability.NoCache);
        ctx.Response.Cache.SetNoStore();

        if (ctx.Request.Headers["X-Requested-With"] != "Comunicador") { Fail(ctx, 400, "requisição inválida"); return; }

        ChatUser me = Auth.Current(ctx);
        if (me == null) { Fail(ctx, 401, "sessão expirada"); return; }
        if (me.MustChangePassword) { Fail(ctx, 403, "troca de senha pendente"); return; }

        if (a == "poll" && method == "GET") Poll(ctx, me);
        else if (method != "POST") Fail(ctx, 405, "método inválido");
        else if (a == "send") SendText(ctx, me);
        else if (a == "buzz") SendBuzz(ctx, me);
        else if (a == "upload") Upload(ctx, me);
        else if (a == "typing") SetTyping(ctx, me);
        else Fail(ctx, 404, "ação desconhecida");
    }

    // ------------------------------------------------------------------ poll
    private void Poll(HttpContext ctx, ChatUser me)
    {
        long since;
        long.TryParse(ctx.Request.QueryString["since"], out since);

        var users = new List<object>();
        var messages = new List<Dictionary<string, object>>();

        using (var conn = Db.Open())
        {
            using (var cmd = new SqlCommand("UPDATE dbo.ChatUser SET LastSeen = SYSDATETIME() WHERE UserId = @me", conn))
            {
                cmd.Parameters.AddWithValue("@me", me.UserId);
                cmd.ExecuteNonQuery();
            }

            using (var cmd = new SqlCommand(@"SELECT UserId, DisplayName, IsActive,
                    CASE WHEN LastSeen > DATEADD(SECOND, -@sec, SYSDATETIME()) THEN 1 ELSE 0 END AS Online
                    FROM dbo.ChatUser ORDER BY DisplayName", conn))
            {
                cmd.Parameters.AddWithValue("@sec", OnlineSeconds);
                using (var r = cmd.ExecuteReader())
                    while (r.Read())
                        users.Add(new
                        {
                            id = (int)r["UserId"],
                            name = (string)r["DisplayName"],
                            active = (bool)r["IsActive"],
                            online = (int)r["Online"] == 1
                        });
            }

            using (var cmd = new SqlCommand(@"SELECT TOP (@n) m.MessageId, m.FromUserId, m.ToUserId, m.Body, m.Kind, m.SentAt,
                           f.FileId, f.ContentType, f.Size
                    FROM dbo.ChatMessage m
                    LEFT JOIN dbo.ChatFile f ON f.MessageId = m.MessageId
                    WHERE m.MessageId > @since
                      AND (m.ToUserId IS NULL OR m.ToUserId = @me OR m.FromUserId = @me)
                    ORDER BY m.MessageId", conn))
            {
                cmd.Parameters.AddWithValue("@n", PageSize);
                cmd.Parameters.AddWithValue("@since", since);
                cmd.Parameters.AddWithValue("@me", me.UserId);
                using (var r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        var m = new Dictionary<string, object>
                        {
                            { "id", (long)r["MessageId"] },
                            { "from", (int)r["FromUserId"] },
                            { "to", r["ToUserId"] == DBNull.Value ? (int?)null : (int)r["ToUserId"] },
                            { "body", (string)r["Body"] },
                            { "kind", (byte)r["Kind"] },
                            { "at", ((DateTime)r["SentAt"]).ToString("HH:mm") }
                        };
                        if (r["FileId"] != DBNull.Value)
                        {
                            m["fileId"] = (long)r["FileId"];
                            m["size"] = (int)r["Size"];
                            m["image"] = ((string)r["ContentType"]).StartsWith("image/");
                        }
                        messages.Add(m);
                    }
            }
        }

        DateTime cutoff = DateTime.Now.AddSeconds(-TypingSeconds);
        var typing = Typing
            .Where(kv => kv.Key != me.UserId && kv.Value.At > cutoff && (kv.Value.To == null || kv.Value.To == me.UserId))
            .Select(kv => new { from = kv.Key, to = kv.Value.To })
            .ToList();

        Write(ctx, new
        {
            me = me.UserId,
            today = DateTime.Now.ToString("yyyy-MM-dd"),
            more = messages.Count == PageSize,
            users = users,
            messages = messages,
            typing = typing
        });
    }

    // ------------------------------------------------------------------ envio
    private void SendText(HttpContext ctx, ChatUser me)
    {
        // Unvalidated: mensagens podem conter "<", ">" etc. O cliente sempre
        // exibe o texto com textContent, nunca como HTML.
        string body = (ctx.Request.Unvalidated.Form["body"] ?? "").Trim();
        if (body.Length == 0) { Fail(ctx, 400, "mensagem vazia"); return; }
        if (body.Length > MaxBody) { Fail(ctx, 400, "mensagem longa demais (máx. " + MaxBody + " caracteres)"); return; }

        using (var conn = Db.Open())
        {
            int? to;
            if (!TryGetRecipient(ctx, conn, me, false, out to)) return;
            long id = InsertMessage(conn, null, me.UserId, to, body, KindText);
            TypingInfo ignored;
            Typing.TryRemove(me.UserId, out ignored);
            Write(ctx, new { ok = true, id = id });
        }
    }

    private void SendBuzz(HttpContext ctx, ChatUser me)
    {
        using (var conn = Db.Open())
        {
            int? to;
            if (!TryGetRecipient(ctx, conn, me, true, out to)) return;

            using (var cmd = new SqlCommand(@"SELECT COUNT(*) FROM dbo.ChatMessage
                    WHERE FromUserId = @me AND ToUserId = @to AND Kind = @kind
                      AND SentAt > DATEADD(SECOND, -@sec, SYSDATETIME())", conn))
            {
                cmd.Parameters.AddWithValue("@me", me.UserId);
                cmd.Parameters.AddWithValue("@to", to.Value);
                cmd.Parameters.AddWithValue("@kind", KindBuzz);
                cmd.Parameters.AddWithValue("@sec", BuzzCooldownSeconds);
                if ((int)cmd.ExecuteScalar() > 0) { Fail(ctx, 429, "calma! espere alguns segundos para tocar a campainha de novo"); return; }
            }

            long id = InsertMessage(conn, null, me.UserId, to, "campainha", KindBuzz);
            Write(ctx, new { ok = true, id = id });
        }
    }

    private void Upload(HttpContext ctx, ChatUser me)
    {
        HttpPostedFile file = ctx.Request.Files["file"];
        if (file == null || file.ContentLength == 0) { Fail(ctx, 400, "nenhum arquivo recebido"); return; }
        if (file.ContentLength > MaxFileBytes) { Fail(ctx, 413, "arquivo maior que " + (MaxFileBytes / 1024 / 1024) + " MB"); return; }

        byte[] data;
        using (var ms = new MemoryStream(file.ContentLength))
        {
            file.InputStream.CopyTo(ms);
            data = ms.ToArray();
        }

        string name = SafeFileName(file.FileName);
        string contentType = DetectImageType(data) ?? "application/octet-stream";

        using (var conn = Db.Open())
        {
            int? to;
            if (!TryGetRecipient(ctx, conn, me, false, out to)) return;

            using (var tx = conn.BeginTransaction())
            {
                long msgId = InsertMessage(conn, tx, me.UserId, to, name, KindFile);
                using (var cmd = new SqlCommand(@"INSERT INTO dbo.ChatFile (MessageId, FileName, ContentType, Size, Data)
                        VALUES (@m, @n, @ct, @s, @d)", conn, tx))
                {
                    cmd.Parameters.AddWithValue("@m", msgId);
                    cmd.Parameters.AddWithValue("@n", name);
                    cmd.Parameters.AddWithValue("@ct", contentType);
                    cmd.Parameters.AddWithValue("@s", data.Length);
                    cmd.Parameters.Add("@d", System.Data.SqlDbType.VarBinary, -1).Value = data;
                    cmd.ExecuteNonQuery();
                }
                tx.Commit();
                Write(ctx, new { ok = true, id = msgId });
            }
        }
    }

    private void SetTyping(HttpContext ctx, ChatUser me)
    {
        string toRaw = ctx.Request.Unvalidated.Form["to"];
        int t;
        int? to = (!string.IsNullOrEmpty(toRaw) && int.TryParse(toRaw, out t)) ? t : (int?)null;
        Typing[me.UserId] = new TypingInfo { To = to, At = DateTime.Now };
        Write(ctx, new { ok = true });
    }

    // ------------------------------------------------------------------ download
    private void DownloadFile(HttpContext ctx, ChatUser me)
    {
        long id;
        if (!long.TryParse(ctx.Request.QueryString["id"], out id)) { ctx.Response.StatusCode = 404; return; }

        string name, contentType;
        byte[] data;
        using (var conn = Db.Open())
        using (var cmd = new SqlCommand(@"SELECT f.FileName, f.ContentType, f.Data
                FROM dbo.ChatFile f
                JOIN dbo.ChatMessage m ON m.MessageId = f.MessageId
                WHERE f.FileId = @id
                  AND (m.ToUserId IS NULL OR m.ToUserId = @me OR m.FromUserId = @me)", conn))
        {
            cmd.Parameters.AddWithValue("@id", id);
            cmd.Parameters.AddWithValue("@me", me.UserId);
            using (var r = cmd.ExecuteReader())
            {
                if (!r.Read()) { ctx.Response.StatusCode = 404; return; }
                name = (string)r["FileName"];
                contentType = (string)r["ContentType"];
                data = (byte[])r["Data"];
            }
        }

        bool inline = contentType.StartsWith("image/") && ctx.Request.QueryString["dl"] != "1";
        string ascii = new string(name.Select(c => c < 128 && c != '"' && c != '\\' && !char.IsControl(c) ? c : '_').ToArray());

        ctx.Response.ContentType = contentType;
        ctx.Response.AddHeader("Content-Disposition",
            (inline ? "inline" : "attachment") + "; filename=\"" + ascii + "\"; filename*=UTF-8''" + Uri.EscapeDataString(name));
        // O arquivo nunca roda como página do site, mesmo que alguém envie um HTML
        ctx.Response.AddHeader("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self'; style-src 'unsafe-inline'");
        ctx.Response.BinaryWrite(data);
    }

    // ------------------------------------------------------------------ auxiliares
    private bool TryGetRecipient(HttpContext ctx, SqlConnection conn, ChatUser me, bool required, out int? to)
    {
        to = null;
        string toRaw = ctx.Request.Unvalidated.Form["to"];
        if (string.IsNullOrEmpty(toRaw))
        {
            if (required) { Fail(ctx, 400, "escolha uma conversa individual"); return false; }
            return true;
        }

        int t;
        if (!int.TryParse(toRaw, out t) || t == me.UserId) { Fail(ctx, 400, "destinatário inválido"); return false; }

        using (var cmd = new SqlCommand("SELECT COUNT(*) FROM dbo.ChatUser WHERE UserId = @id AND IsActive = 1", conn))
        {
            cmd.Parameters.AddWithValue("@id", t);
            if ((int)cmd.ExecuteScalar() == 0) { Fail(ctx, 400, "destinatário inexistente ou desativado"); return false; }
        }
        to = t;
        return true;
    }

    private static long InsertMessage(SqlConnection conn, SqlTransaction tx, int from, int? to, string body, byte kind)
    {
        using (var cmd = new SqlCommand(@"INSERT INTO dbo.ChatMessage (FromUserId, ToUserId, Body, Kind)
                OUTPUT INSERTED.MessageId VALUES (@from, @to, @body, @kind)", conn, tx))
        {
            cmd.Parameters.AddWithValue("@from", from);
            cmd.Parameters.AddWithValue("@to", to.HasValue ? (object)to.Value : DBNull.Value);
            cmd.Parameters.AddWithValue("@body", body);
            cmd.Parameters.AddWithValue("@kind", kind);
            return (long)cmd.ExecuteScalar();
        }
    }

    /// <summary>Tipo de imagem pelos primeiros bytes (não confia na extensão nem no navegador).</summary>
    private static string DetectImageType(byte[] d)
    {
        if (d.Length >= 8 && d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) return "image/png";
        if (d.Length >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return "image/jpeg";
        if (d.Length >= 6 && d[0] == 0x47 && d[1] == 0x49 && d[2] == 0x46 && d[3] == 0x38) return "image/gif";
        if (d.Length >= 12 && d[0] == 0x52 && d[1] == 0x49 && d[2] == 0x46 && d[3] == 0x46
            && d[8] == 0x57 && d[9] == 0x45 && d[10] == 0x42 && d[11] == 0x50) return "image/webp";
        return null;
    }

    private static string SafeFileName(string raw)
    {
        string name = raw ?? "";
        int slash = Math.Max(name.LastIndexOf('\\'), name.LastIndexOf('/'));
        if (slash >= 0) name = name.Substring(slash + 1);
        var sb = new StringBuilder();
        foreach (char c in name) if (!char.IsControl(c)) sb.Append(c);
        name = sb.ToString().Trim();
        if (name.Length == 0) name = "arquivo";
        if (name.Length > 200) name = name.Substring(name.Length - 200);
        return name;
    }

    private static void Write(HttpContext ctx, object data)
    {
        ctx.Response.Write(new JavaScriptSerializer().Serialize(data));
    }

    private static void Fail(HttpContext ctx, int status, string message)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.TrySkipIisCustomErrors = true;
        Write(ctx, new { ok = false, error = message });
    }
}
