using System;
using System.Configuration;
using System.Data.SqlClient;
using System.Security.Cryptography;
using System.Web;
using System.Web.Security;

/// <summary>Usuário autenticado, carregado do banco a cada requisição.</summary>
public class ChatUser
{
    public int UserId;
    public string Login;
    public string DisplayName;
    public bool IsAdmin;
    public bool MustChangePassword;
}

public static class Db
{
    public static SqlConnection Open()
    {
        var conn = new SqlConnection(ConfigurationManager.ConnectionStrings["ComunicadorDB"].ConnectionString);
        conn.Open();
        return conn;
    }
}

public static class Auth
{
    private const int Iterations = 100000;
    private const int MaxFailedLogins = 5;
    private const int LockMinutes = 15;
    public const int MinPasswordLength = 8;

    public static byte[] NewSalt()
    {
        var salt = new byte[16];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
        return salt;
    }

    public static byte[] Hash(string password, byte[] salt)
    {
        using (var kdf = new Rfc2898DeriveBytes(password, salt, Iterations))
            return kdf.GetBytes(32);
    }

    private static bool SlowEquals(byte[] a, byte[] b)
    {
        if (a == null || b == null || a.Length != b.Length) return false;
        int diff = 0;
        for (int i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
        return diff == 0;
    }

    /// <summary>Valida login/senha. Retorna null e preenche 'error' em caso de falha.</summary>
    public static ChatUser TryLogin(string login, string password, out string error)
    {
        error = "Usuário ou senha inválidos.";
        if (string.IsNullOrWhiteSpace(login) || string.IsNullOrEmpty(password)) return null;

        using (var conn = Db.Open())
        {
            int userId; byte[] hash, salt; bool active; DateTime? lockedUntil; ChatUser user;
            using (var cmd = new SqlCommand(@"SELECT UserId, Login, DisplayName, PasswordHash, Salt, IsAdmin,
                    IsActive, MustChangePassword, LockedUntil FROM dbo.ChatUser WHERE Login = @l", conn))
            {
                cmd.Parameters.AddWithValue("@l", login.Trim());
                using (var r = cmd.ExecuteReader())
                {
                    if (!r.Read())
                    {
                        Hash(password, NewSalt()); // custo igual, para não revelar se o login existe
                        return null;
                    }
                    userId = (int)r["UserId"];
                    hash = (byte[])r["PasswordHash"];
                    salt = (byte[])r["Salt"];
                    active = (bool)r["IsActive"];
                    lockedUntil = r["LockedUntil"] as DateTime?;
                    user = new ChatUser
                    {
                        UserId = userId,
                        Login = (string)r["Login"],
                        DisplayName = (string)r["DisplayName"],
                        IsAdmin = (bool)r["IsAdmin"],
                        MustChangePassword = (bool)r["MustChangePassword"]
                    };
                }
            }

            if (lockedUntil.HasValue && lockedUntil.Value > DateTime.Now)
            {
                error = "Conta bloqueada temporariamente por excesso de tentativas. Tente novamente mais tarde.";
                return null;
            }

            if (!SlowEquals(Hash(password, salt), hash))
            {
                using (var cmd = new SqlCommand(@"UPDATE dbo.ChatUser
                        SET FailedLogins = FailedLogins + 1,
                            LockedUntil = CASE WHEN FailedLogins + 1 >= @max THEN DATEADD(MINUTE, @min, SYSDATETIME()) ELSE LockedUntil END
                        WHERE UserId = @id", conn))
                {
                    cmd.Parameters.AddWithValue("@max", MaxFailedLogins);
                    cmd.Parameters.AddWithValue("@min", LockMinutes);
                    cmd.Parameters.AddWithValue("@id", userId);
                    cmd.ExecuteNonQuery();
                }
                return null;
            }

            if (!active)
            {
                error = "Usuário desativado. Fale com o administrador.";
                return null;
            }

            using (var cmd = new SqlCommand(@"UPDATE dbo.ChatUser SET FailedLogins = 0, LockedUntil = NULL,
                    LastSeen = SYSDATETIME() WHERE UserId = @id", conn))
            {
                cmd.Parameters.AddWithValue("@id", userId);
                cmd.ExecuteNonQuery();
            }
            error = null;
            return user;
        }
    }

    /// <summary>
    /// Usuário da requisição atual (cookie de Forms Auth), relido do banco para que
    /// desativações tenham efeito imediato. Retorna null se não autenticado/inativo.
    /// </summary>
    public static ChatUser Current(HttpContext ctx)
    {
        if (ctx.Items["ChatUser"] != null) return (ChatUser)ctx.Items["ChatUser"];
        if (ctx.User == null || !ctx.User.Identity.IsAuthenticated) return null;

        using (var conn = Db.Open())
        using (var cmd = new SqlCommand(@"SELECT UserId, Login, DisplayName, IsAdmin, MustChangePassword
                FROM dbo.ChatUser WHERE Login = @l AND IsActive = 1", conn))
        {
            cmd.Parameters.AddWithValue("@l", ctx.User.Identity.Name);
            using (var r = cmd.ExecuteReader())
            {
                if (!r.Read()) return null;
                var u = new ChatUser
                {
                    UserId = (int)r["UserId"],
                    Login = (string)r["Login"],
                    DisplayName = (string)r["DisplayName"],
                    IsAdmin = (bool)r["IsAdmin"],
                    MustChangePassword = (bool)r["MustChangePassword"]
                };
                ctx.Items["ChatUser"] = u;
                return u;
            }
        }
    }

    /// <summary>Para páginas: exige usuário válido (e admin, se pedido); redireciona caso contrário.</summary>
    public static ChatUser Require(HttpContext ctx, bool adminOnly = false, bool allowMustChange = false)
    {
        var u = Current(ctx);
        if (u == null)
        {
            FormsAuthentication.SignOut();
            ctx.Response.Redirect(FormsAuthentication.LoginUrl, true);
            return null;
        }
        if (u.MustChangePassword && !allowMustChange)
        {
            ctx.Response.Redirect("~/ChangePassword.aspx", true);
            return null;
        }
        if (adminOnly && !u.IsAdmin)
        {
            ctx.Response.StatusCode = 403;
            ctx.Response.Write("Acesso restrito ao administrador.");
            ctx.Response.End();
            return null;
        }
        return u;
    }

    public static void SetPassword(SqlConnection conn, int userId, string password, bool mustChange)
    {
        var salt = NewSalt();
        using (var cmd = new SqlCommand(@"UPDATE dbo.ChatUser SET PasswordHash = @h, Salt = @s,
                MustChangePassword = @m, FailedLogins = 0, LockedUntil = NULL WHERE UserId = @id", conn))
        {
            cmd.Parameters.AddWithValue("@h", Hash(password, salt));
            cmd.Parameters.AddWithValue("@s", salt);
            cmd.Parameters.AddWithValue("@m", mustChange);
            cmd.Parameters.AddWithValue("@id", userId);
            cmd.ExecuteNonQuery();
        }
    }

    public static int CreateUser(SqlConnection conn, string login, string displayName, string password, bool isAdmin)
    {
        var salt = NewSalt();
        using (var cmd = new SqlCommand(@"INSERT INTO dbo.ChatUser (Login, DisplayName, PasswordHash, Salt, IsAdmin, MustChangePassword)
                OUTPUT INSERTED.UserId VALUES (@l, @d, @h, @s, @a, 1)", conn))
        {
            cmd.Parameters.AddWithValue("@l", login.Trim());
            cmd.Parameters.AddWithValue("@d", displayName.Trim());
            cmd.Parameters.AddWithValue("@h", Hash(password, salt));
            cmd.Parameters.AddWithValue("@s", salt);
            cmd.Parameters.AddWithValue("@a", isAdmin);
            return (int)cmd.ExecuteScalar();
        }
    }

    /// <summary>Senha temporária legível (sem caracteres ambíguos).</summary>
    public static string TempPassword()
    {
        const string chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var bytes = new byte[10];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        var c = new char[10];
        for (int i = 0; i < c.Length; i++) c[i] = chars[bytes[i] % chars.Length];
        return new string(c);
    }
}
