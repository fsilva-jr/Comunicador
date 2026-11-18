/* =====================================================================
   Comunicador - instalação do banco de dados
   Execute no mesmo SQL Server usado pelo AXMonitor (como sysadmin).
   Antes de executar, ajuste as duas variáveis abaixo:
     - @AppPoolIdentity : identidade do Application Pool do IIS
                          (ex.: 'IIS APPPOOL\Comunicador' se o SQL estiver
                          na mesma máquina, ou 'DOMINIO\SERVIDORWEB$' se o
                          IIS estiver em outro servidor)
   ===================================================================== */
USE master;
GO
IF DB_ID('Comunicador') IS NULL
    CREATE DATABASE Comunicador;
GO
-- Dados efêmeros: sem necessidade de log completo
ALTER DATABASE Comunicador SET RECOVERY SIMPLE;
GO
USE Comunicador;
GO

IF OBJECT_ID('dbo.ChatUser') IS NULL
CREATE TABLE dbo.ChatUser (
    UserId             INT IDENTITY(1,1) PRIMARY KEY,
    Login              NVARCHAR(50)  NOT NULL CONSTRAINT UQ_ChatUser_Login UNIQUE,
    DisplayName        NVARCHAR(100) NOT NULL,
    PasswordHash       VARBINARY(32) NOT NULL,
    Salt               VARBINARY(16) NOT NULL,
    IsAdmin            BIT NOT NULL CONSTRAINT DF_ChatUser_IsAdmin  DEFAULT 0,
    IsActive           BIT NOT NULL CONSTRAINT DF_ChatUser_IsActive DEFAULT 1,
    MustChangePassword BIT NOT NULL CONSTRAINT DF_ChatUser_MustChg  DEFAULT 1,
    FailedLogins       INT NOT NULL CONSTRAINT DF_ChatUser_Failed   DEFAULT 0,
    LockedUntil        DATETIME2 NULL,
    LastSeen           DATETIME2 NULL,
    CreatedAt          DATETIME2 NOT NULL CONSTRAINT DF_ChatUser_Created DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dbo.ChatMessage') IS NULL
CREATE TABLE dbo.ChatMessage (
    MessageId  BIGINT IDENTITY(1,1) PRIMARY KEY,
    FromUserId INT NOT NULL REFERENCES dbo.ChatUser(UserId),
    ToUserId   INT NULL     REFERENCES dbo.ChatUser(UserId),   -- NULL = sala geral
    Body       NVARCHAR(2000) NOT NULL,
    SentAt     DATETIME2 NOT NULL CONSTRAINT DF_ChatMessage_SentAt DEFAULT SYSDATETIME(),
    Kind       TINYINT   NOT NULL CONSTRAINT DF_ChatMessage_Kind   DEFAULT 0   -- 0 texto, 1 campainha, 2 arquivo
);
GO

-- Arquivos anexados; somem junto com a mensagem (limpeza diária)
IF OBJECT_ID('dbo.ChatFile') IS NULL
CREATE TABLE dbo.ChatFile (
    FileId      BIGINT IDENTITY(1,1) PRIMARY KEY,
    MessageId   BIGINT NOT NULL
                CONSTRAINT FK_ChatFile_Message REFERENCES dbo.ChatMessage(MessageId) ON DELETE CASCADE,
    FileName    NVARCHAR(255) NOT NULL,
    ContentType VARCHAR(100)  NOT NULL,
    Size        INT           NOT NULL,
    Data        VARBINARY(MAX) NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ChatFile_MessageId')
    CREATE INDEX IX_ChatFile_MessageId ON dbo.ChatFile (MessageId);
GO

/* ---------------------------------------------------------------------
   Permissões para o Application Pool do IIS
   --------------------------------------------------------------------- */
DECLARE @AppPoolIdentity SYSNAME = N'CHANGE_ME\CHANGE_ME$';
DECLARE @sql NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @AppPoolIdentity)
BEGIN
    SET @sql = N'USE master; CREATE LOGIN ' + QUOTENAME(@AppPoolIdentity) + N' FROM WINDOWS;';
    EXEC (@sql);
END
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @AppPoolIdentity)
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@AppPoolIdentity) + N' FOR LOGIN ' + QUOTENAME(@AppPoolIdentity) + N';';
    EXEC (@sql);
END
SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@AppPoolIdentity) + N';'
         + N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@AppPoolIdentity) + N';';
EXEC (@sql);
GO

/* ---------------------------------------------------------------------
   Job do SQL Agent: limpeza diária das mensagens (00:05)
   Apaga tudo o que foi enviado antes do dia corrente.
   --------------------------------------------------------------------- */
USE msdb;
GO
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Comunicador - Limpeza diaria')
    EXEC msdb.dbo.sp_delete_job @job_name = N'Comunicador - Limpeza diaria';
GO
EXEC msdb.dbo.sp_add_job
    @job_name = N'Comunicador - Limpeza diaria',
    @description = N'Remove todas as mensagens do Comunicador enviadas antes de hoje.';
EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'Comunicador - Limpeza diaria',
    @step_name = N'Apagar mensagens',
    @subsystem = N'TSQL',
    @database_name = N'Comunicador',
    @command = N'DELETE FROM dbo.ChatMessage WHERE SentAt < CAST(SYSDATETIME() AS DATE);';
EXEC msdb.dbo.sp_add_schedule
    @schedule_name = N'Comunicador - Diario 00:05',
    @freq_type = 4,            -- diário
    @freq_interval = 1,
    @active_start_time = 000500;
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'Comunicador - Limpeza diaria',
    @schedule_name = N'Comunicador - Diario 00:05';
EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'Comunicador - Limpeza diaria';
GO
