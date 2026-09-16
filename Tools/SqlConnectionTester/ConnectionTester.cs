using System.Data;
using System.Text;
using Microsoft.Data.SqlClient;

namespace SqlConnectionTester;

public class TestResult
{
    public string Name { get; set; } = "";
    public string ConnectionString { get; set; } = "";
    public string? TestText { get; set; }
    public string Status { get; set; } = "Failure";      // Success | Failure
    public string? ErrorMessage { get; set; }
    public DateTime TestedAt { get; set; } = DateTime.Now;
    public long ElapsedMs { get; set; }

    public bool Succeeded => Status == "Success";
}

public static class ConnectionTester
{
    /// <summary>
    /// Opens the connection, reads the single row from the test table and reports what happened.
    /// Read-only: nothing is created or changed on the server.
    /// </summary>
    public static TestResult Test(ConnectionProfile profile, bool maskPassword = true)
    {
        var connectionString = profile.Build();
        var result = new TestResult
        {
            Name = profile.Name,
            ConnectionString = maskPassword ? ConnectionProfile.Mask(connectionString) : connectionString
        };

        var started = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = connection.CreateCommand();
            command.CommandText = string.IsNullOrWhiteSpace(profile.Query) ? ConnectionProfile.DefaultQuery : profile.Query;
            command.CommandTimeout = profile.CommandTimeoutSeconds;

            using var reader = command.ExecuteReader();
            var table = new DataTable();
            table.Load(reader);

            if (table.Rows.Count == 0)
            {
                result.ErrorMessage = "Connected and read the test table, but it contains no rows.";
            }
            else
            {
                var value = table.Rows[0][0];
                result.TestText = value is DBNull ? null : Convert.ToString(value);
                result.Status = "Success";
                if (table.Rows.Count > 1)
                    result.ErrorMessage = $"Note: the test table returned {table.Rows.Count} rows; the first was used.";
            }
        }
        catch (Exception ex)
        {
            result.ErrorMessage = Describe(ex);
        }
        result.ElapsedMs = started.ElapsedMilliseconds;
        return result;
    }

    /// <summary>
    /// The complete error: every error in a SqlException's collection (number, severity, state, procedure,
    /// line, server), every inner exception, and the client connection id. Nothing is truncated.
    /// </summary>
    public static string Describe(Exception exception)
    {
        var sb = new StringBuilder();
        var ex = exception;
        var level = 0;
        while (ex != null)
        {
            sb.AppendLine($"{(level == 0 ? "" : $"Inner exception ({level}): ")}[{ex.GetType().FullName}] {ex.Message}");

            if (ex is SqlException sql)
            {
                if (sql.ClientConnectionId != Guid.Empty) sb.AppendLine($"Client connection id: {sql.ClientConnectionId}");
                var n = 0;
                foreach (SqlError err in sql.Errors)
                {
                    n++;
                    var detail = $"SQL error {n} of {sql.Errors.Count}: Msg {err.Number}, Level {err.Class}, State {err.State}";
                    if (!string.IsNullOrEmpty(err.Procedure)) detail += $", Procedure {err.Procedure}";
                    if (err.LineNumber > 0) detail += $", Line {err.LineNumber}";
                    if (!string.IsNullOrEmpty(err.Server)) detail += $", Server {err.Server}";
                    sb.AppendLine(detail);
                    sb.AppendLine(err.Message);
                }
            }

            ex = ex.InnerException;
            level++;
        }
        return sb.ToString().TrimEnd();
    }

    public static void ExportCsv(IEnumerable<TestResult> results, string path)
    {
        static string Csv(string? value) => "\"" + (value ?? "").Replace("\"", "\"\"") + "\"";
        using var writer = new StreamWriter(path, false, new UTF8Encoding(true));
        writer.WriteLine("Name,ConnectionString,TestText,Status,ErrorMessage,TestedAt,ElapsedMs");
        foreach (var r in results)
            writer.WriteLine(string.Join(",", Csv(r.Name), Csv(r.ConnectionString), Csv(r.TestText), Csv(r.Status),
                                         Csv(r.ErrorMessage), Csv(r.TestedAt.ToString("s")), r.ElapsedMs));
    }
}
