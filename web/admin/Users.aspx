<%@ Page Language="C#" %>
<%@ Import Namespace="System.Data" %>
<%@ Import Namespace="System.Data.SqlClient" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>
<script runat="server">
    // Limite de usuários ativos (o projeto prevê no máximo 20)
    const int MaxActiveUsers = 20;
    protected ChatUser me;

    protected void Page_Init(object sender, EventArgs e)
    {
        me = Auth.Require(Context, adminOnly: true);
        ViewStateUserKey = me.Login; // proteção contra CSRF nos postbacks
    }

    protected void Page_Load(object sender, EventArgs e)
    {
        if (!IsPostBack) BindUsers();
    }

    void BindUsers()
    {
        var dt = new DataTable();
        using (var conn = Db.Open())
        using (var da = new SqlDataAdapter(@"SELECT UserId, Login, DisplayName, IsAdmin, IsActive, MustChangePassword,
                LockedUntil, LastSeen FROM dbo.ChatUser ORDER BY IsActive DESC, DisplayName", conn))
            da.Fill(dt);
        rptUsers.DataSource = dt;
        rptUsers.DataBind();
    }

    int ActiveCount(SqlConnection conn)
    {
        using (var cmd = new SqlCommand("SELECT COUNT(*) FROM dbo.ChatUser WHERE IsActive = 1", conn))
            return (int)cmd.ExecuteScalar();
    }

    protected void Criar_Click(object sender, EventArgs e)
    {
        string login = txtLogin.Text.Trim(), nome = txtNome.Text.Trim();
        if (!Regex.IsMatch(login, @"^[A-Za-z0-9._-]{3,50}$")) { ShowError("Usuário deve ter 3 a 50 caracteres: letras, números, ponto, hífen ou sublinhado."); return; }
        if (nome.Length < 2 || nome.Length > 100) { ShowError("Informe o nome de exibição."); return; }

        string temp = Auth.TempPassword();
        try
        {
            using (var conn = Db.Open())
            {
                if (ActiveCount(conn) >= MaxActiveUsers) { ShowError("Limite de " + MaxActiveUsers + " usuários ativos atingido."); return; }
                Auth.CreateUser(conn, login, nome, temp, chkAdmin.Checked);
            }
        }
        catch (SqlException ex)
        {
            if (ex.Number == 2627 || ex.Number == 2601) { ShowError("Já existe um usuário com esse login."); return; }
            throw;
        }

        txtLogin.Text = txtNome.Text = "";
        chkAdmin.Checked = false;
        ShowTempPassword("Usuário " + login + " criado.", temp);
        BindUsers();
    }

    protected void Users_Command(object source, RepeaterCommandEventArgs e)
    {
        int id = int.Parse((string)e.CommandArgument);
        bool self = id == me.UserId;

        using (var conn = Db.Open())
        {
            switch (e.CommandName)
            {
                case "reset":
                    string temp = Auth.TempPassword();
                    Auth.SetPassword(conn, id, temp, true);
                    ShowTempPassword("Senha redefinida. O usuário deverá trocá-la no próximo acesso.", temp);
                    break;

                case "toggleActive":
                    if (self) { ShowError("Você não pode desativar a si mesmo."); break; }
                    bool activating;
                    using (var cmd = new SqlCommand("SELECT IsActive FROM dbo.ChatUser WHERE UserId = @id", conn))
                    {
                        cmd.Parameters.AddWithValue("@id", id);
                        activating = !(bool)cmd.ExecuteScalar();
                    }
                    if (activating && ActiveCount(conn) >= MaxActiveUsers) { ShowError("Limite de " + MaxActiveUsers + " usuários ativos atingido."); break; }
                    Exec(conn, "UPDATE dbo.ChatUser SET IsActive = 1 - IsActive WHERE UserId = @id", id);
                    break;

                case "toggleAdmin":
                    if (self) { ShowError("Você não pode remover o seu próprio perfil de administrador."); break; }
                    Exec(conn, "UPDATE dbo.ChatUser SET IsAdmin = 1 - IsAdmin WHERE UserId = @id", id);
                    break;

                case "unlock":
                    Exec(conn, "UPDATE dbo.ChatUser SET FailedLogins = 0, LockedUntil = NULL WHERE UserId = @id", id);
                    break;
            }
        }
        BindUsers();
    }

    protected void Limpar_Click(object sender, EventArgs e)
    {
        int n;
        using (var conn = Db.Open())
        using (var cmd = new SqlCommand("DELETE FROM dbo.ChatMessage", conn))
            n = cmd.ExecuteNonQuery();
        litMsg.Text = "<div class=\"msg-box good\">" + n + " mensagem(ns) apagada(s).</div>";
        BindUsers();
    }

    static void Exec(SqlConnection conn, string sql, int id)
    {
        using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.AddWithValue("@id", id);
            cmd.ExecuteNonQuery();
        }
    }

    void ShowError(string text) { litMsg.Text = "<div class=\"msg-box critical\">" + HttpUtility.HtmlEncode(text) + "</div>"; }
    void ShowTempPassword(string text, string temp)
    {
        litMsg.Text = "<div class=\"msg-box good\">" + HttpUtility.HtmlEncode(text) +
            "<br />Senha temporária: <code>" + HttpUtility.HtmlEncode(temp) + "</code>" +
            "<br /><small>Anote e entregue pessoalmente; ela não será exibida novamente.</small></div>";
    }

    protected static string H(object o) { return HttpUtility.HtmlEncode(Convert.ToString(o)); }
    protected static string When(object o) { return o == DBNull.Value ? "—" : ((DateTime)o).ToString("dd/MM/yyyy HH:mm"); }
    protected static bool IsLocked(object o) { return o != DBNull.Value && (DateTime)o > DateTime.Now; }
</script>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <script>(function(){try{var t=localStorage.getItem("comunicador-theme");if(t)document.documentElement.setAttribute("data-theme",t);}catch(e){}})();</script>
    <title>Usuários – Comunicador</title>
    <link rel="stylesheet" href="../site.css" />
</head>
<body>
    <div class="corner"><button type="button" class="theme-toggle"></button></div>
    <div class="page">
        <div class="nav"><a href="../Chat.aspx">&larr; Voltar ao chat</a></div>
        <h1>Usuários</h1>
        <p class="sub">Somente administradores podem cadastrar usuários. Limite: <%= MaxActiveUsers %> ativos.</p>

        <asp:Literal ID="litMsg" runat="server" />

        <form runat="server" ValidateRequestMode="Disabled">
            <div class="card">
                <div class="inline">
                    <label>Usuário (login)<asp:TextBox ID="txtLogin" runat="server" MaxLength="50" /></label>
                    <label>Nome de exibição<asp:TextBox ID="txtNome" runat="server" MaxLength="100" /></label>
                    <label class="check"><asp:CheckBox ID="chkAdmin" runat="server" /> Administrador</label>
                    <asp:Button ID="btnCriar" runat="server" Text="Cadastrar" CssClass="btn" OnClick="Criar_Click" />
                </div>
            </div>

            <div class="card">
                <table>
                    <tr><th>Nome</th><th>Usuário</th><th>Situação</th><th>Perfil</th><th>Último acesso</th><th>Ações</th></tr>
                    <asp:Repeater ID="rptUsers" runat="server" OnItemCommand="Users_Command">
                        <ItemTemplate>
                            <tr>
                                <td><%# H(Eval("DisplayName")) %></td>
                                <td><%# H(Eval("Login")) %></td>
                                <td>
                                    <%# (bool)Eval("IsActive") ? "<span class=\"tag on\">Ativo</span>" : "<span class=\"tag off\">Inativo</span>" %>
                                    <%# IsLocked(Eval("LockedUntil")) ? " <span class=\"tag off\">Bloqueado</span>" : "" %>
                                    <%# (bool)Eval("MustChangePassword") ? " <span class=\"tag\">Senha temporária</span>" : "" %>
                                </td>
                                <td><%# (bool)Eval("IsAdmin") ? "<span class=\"tag admin\">Admin</span>" : "Usuário" %></td>
                                <td><%# When(Eval("LastSeen")) %></td>
                                <td>
                                    <asp:Button runat="server" CssClass="btn secondary small" Text="Redefinir senha"
                                        CommandName="reset" CommandArgument='<%# Eval("UserId") %>'
                                        OnClientClick="return confirm('Gerar nova senha temporária para este usuário?');" />
                                    <asp:Button runat="server" CssClass="btn secondary small"
                                        Text='<%# (bool)Eval("IsActive") ? "Desativar" : "Ativar" %>'
                                        CommandName="toggleActive" CommandArgument='<%# Eval("UserId") %>' />
                                    <asp:Button runat="server" CssClass="btn secondary small"
                                        Text='<%# (bool)Eval("IsAdmin") ? "Remover admin" : "Tornar admin" %>'
                                        CommandName="toggleAdmin" CommandArgument='<%# Eval("UserId") %>' />
                                    <asp:Button runat="server" CssClass="btn secondary small" Text="Desbloquear"
                                        Visible='<%# IsLocked(Eval("LockedUntil")) %>'
                                        CommandName="unlock" CommandArgument='<%# Eval("UserId") %>' />
                                </td>
                            </tr>
                        </ItemTemplate>
                    </asp:Repeater>
                </table>
            </div>

            <div class="card">
                <p class="sub" style="margin-bottom:12px">As mensagens são apagadas automaticamente todos os dias às 00:05. Use o botão abaixo para apagar tudo imediatamente.</p>
                <asp:Button ID="btnLimpar" runat="server" Text="Apagar todas as mensagens agora" CssClass="btn danger"
                    OnClick="Limpar_Click" OnClientClick="return confirm('Apagar TODAS as mensagens de todos os usuários agora?');" />
            </div>
        </form>
    </div>
    <script src="../site.js"></script>
</body>
</html>
