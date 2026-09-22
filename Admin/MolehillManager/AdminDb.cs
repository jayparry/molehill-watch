using System.Data;
using System.Text;
using Microsoft.Data.SqlClient;

namespace MolehillManager;

/// <summary>What a stored procedure returned: its result sets plus any PRINT messages (warnings, notes).</summary>
public sealed class ProcResult
{
    public List<DataTable> Tables { get; } = new();
    public List<string> Messages { get; } = new();
    public DataTable? First => Tables.Count > 0 ? Tables[0] : null;
}

/// <summary>Thin access layer over the MolehillAdmin database. All business rules live in the database.</summary>
public sealed class AdminDb
{
    public string ConnectionString { get; }

    public AdminDb(string connectionString) => ConnectionString = connectionString;

    private SqlConnection Open()
    {
        var connection = new SqlConnection(ConnectionString);
        connection.Open();
        return connection;
    }

    public DataTable Query(string sql, params (string Name, object? Value)[] parameters)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.CommandTimeout = 120;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        var table = new DataTable();
        using var reader = command.ExecuteReader();
        table.Load(reader);
        return table;
    }

    public int Execute(string sql, params (string Name, object? Value)[] parameters)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return command.ExecuteNonQuery();
    }

    public object? Scalar(string sql, params (string Name, object? Value)[] parameters)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        var result = command.ExecuteScalar();
        return result is DBNull ? null : result;
    }

    /// <summary>Runs a stored procedure, capturing every result set and every PRINT message.</summary>
    public ProcResult Proc(string name, params (string Name, object? Value)[] parameters)
    {
        var result = new ProcResult();
        using var connection = Open();
        connection.InfoMessage += (_, e) =>
        {
            foreach (SqlError error in e.Errors)
                if (!string.IsNullOrWhiteSpace(error.Message) && !error.Message.StartsWith("Warning: Null value is eliminated"))
                    result.Messages.Add(error.Message);
        };
        using var command = connection.CreateCommand();
        command.CommandText = name;
        command.CommandType = CommandType.StoredProcedure;
        command.CommandTimeout = 300;
        foreach (var (pName, value) in parameters)
            if (value != null) command.Parameters.AddWithValue(pName, value);   // omitted = use the procedure's default

        using var reader = command.ExecuteReader();
        while (!reader.IsClosed)
        {
            var table = new DataTable();
            table.Load(reader);      // moves on to the next result set, and closes after the last
            if (table.Columns.Count > 0) result.Tables.Add(table);
        }
        return result;
    }

    /// <summary>The complete error text, including every SQL error and inner exception.</summary>
    public static string Describe(Exception exception)
    {
        var sb = new StringBuilder();
        var ex = exception;
        var level = 0;
        while (ex != null)
        {
            if (ex is SqlException sql)
            {
                // the messages themselves are what matters here: RAISERROR text is written for people
                foreach (SqlError err in sql.Errors) sb.AppendLine(err.Message);
                if (level == 0 && sql.Errors.Count > 0) { ex = ex.InnerException; level++; continue; }
            }
            else
            {
                sb.AppendLine($"{(level == 0 ? "" : $"Inner exception ({level}): ")}{ex.Message}");
            }
            ex = ex.InnerException;
            level++;
        }
        return sb.ToString().TrimEnd();
    }
}
