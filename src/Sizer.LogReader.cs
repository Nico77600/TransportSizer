// Transport Sizer - reader of the CSV files of Exchange Log Report (compiled by Add-Type on first use).
// Author: Nicolas Fabert. C# 5 (csc of .NET Framework 4.x for Windows PowerShell 5.1, Roslyn for PowerShell 7).
// One pass over each file, with the aggregates only in memory: a detailed report of a week can have millions of rows.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace TransportSizer
{
    /// <summary>Rows of a CSV file: delimiter guessed from the header, fields in double quotes (RFC 4180), line breaks inside quotes.</summary>
    public sealed class CsvRows : IDisposable
    {
        readonly TextReader reader;
        readonly StringBuilder field = new StringBuilder();
        char separator = ';';
        bool[] keep;

        public string[] Header { get; private set; }

        public CsvRows(string path)
        {
            reader = new StreamReader(path, Encoding.UTF8, true, 1 << 16);
            string line = reader.ReadLine();
            if (line == null) throw new InvalidDataException("Fichier vide : " + path);
            int best = 0;
            foreach (char candidate in new[] { ';', ',', '\t' })
            {
                int count = line.Split(candidate).Length;
                if (count > best) { best = count; separator = candidate; }
            }
            var names = new List<string>();
            foreach (string name in line.Split(separator)) names.Add(name.Trim().Trim('"'));
            Header = names.ToArray();
        }

        public int Index(string name) { return Array.IndexOf(Header, name); }

        /// <summary>Only these columns are materialized (the routes and transcripts are large).</summary>
        public void Keep(params int[] columns)
        {
            keep = new bool[Header.Length];
            foreach (int c in columns) if (c >= 0 && c < keep.Length) keep[c] = true;
        }

        /// <summary>The next row (null at the end); the columns not kept are null.</summary>
        public string[] Next()
        {
            var row = new string[Header.Length];
            int column = 0, c;
            bool quoted = false, any = false;
            field.Clear();
            while ((c = reader.Read()) != -1)
            {
                any = true;
                char ch = (char)c;
                if (quoted)
                {
                    if (ch == '"')
                    {
                        if (reader.Peek() == '"') { reader.Read(); Append('"', column); }
                        else quoted = false;
                    }
                    else Append(ch, column);
                }
                else if (ch == '"') quoted = true;
                else if (ch == separator) { Store(row, column); column++; }
                else if (ch == '\r') { if (reader.Peek() == '\n') reader.Read(); break; }
                else if (ch == '\n') break;
                else Append(ch, column);
            }
            if (!any) return null;
            Store(row, column);
            return row;
        }

        void Append(char ch, int column) { if (keep == null || (column < keep.Length && keep[column])) field.Append(ch); }

        void Store(string[] row, int column)
        {
            if (column < row.Length && (keep == null || keep[column])) row[column] = field.ToString();
            field.Clear();
        }

        public void Dispose() { reader.Dispose(); }

        public static void Require(CsvRows csv, string file, params string[] names)
        {
            var missing = new List<string>();
            foreach (string name in names) if (csv.Index(name) < 0) missing.Add(name);
            if (missing.Count > 0)
                throw new InvalidDataException(file + " : colonne(s) absente(s) : " + string.Join(", ", missing.ToArray()) + ". Fichier d\u2019Exchange Log Report attendu.");
        }
    }

    public sealed class FlowStats
    {
        public double Messages, SizeSum, Sized, Domains, Recipients;
    }

    public sealed class MessageStats
    {
        public readonly Dictionary<string, FlowStats> Flows = new Dictionary<string, FlowStats>(StringComparer.Ordinal);
        public readonly Dictionary<string, double> Hours = new Dictionary<string, double>(StringComparer.Ordinal);
        public readonly Dictionary<string, double> Days = new Dictionary<string, double>(StringComparer.Ordinal);
        public long Refused, Journal, Unknown, Undated;
        public double JournalKB;
        public DateTime First = DateTime.MaxValue, Last = DateTime.MinValue;
        public string[] Servers = new string[0];

        public MessageStats()
        {
            foreach (string key in new[] { "Inbound", "Outbound", "Internal" }) Flows[key] = new FlowStats();
        }
    }

    public sealed class RoleSessions
    {
        public string Role;
        public double Sessions, TlsSessions, SessionsWithMessages, Accepted;
    }

    public static class LogReader
    {
        public const string JournalSender = "MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@";
        static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

        /// <summary>
        /// Messages.csv: messages per flow, sizes, recipient domains sent, recipients, per hour and per day.
        /// Incoming = inbound; Originating = outbound when at least one recipient was sent by SMTP (Edge: always),
        /// internal otherwise. Mail refused during the SMTP session and journal reports are counted apart.
        /// </summary>
        public static MessageStats ReadMessages(string path, bool edge)
        {
            var stats = new MessageStats();
            var servers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var domains = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var csv = new CsvRows(path))
            {
                CsvRows.Require(csv, Path.GetFileName(path), "First event", "Status", "Sender", "Recipients", "Size (KB)", "Direction");
                int iFirst = csv.Index("First event"), iStatus = csv.Index("Status"), iSender = csv.Index("Sender"), iRecipients = csv.Index("Recipients");
                int iSize = csv.Index("Size (KB)"), iDirection = csv.Index("Direction"), iCount = csv.Index("Recipient count"), iServers = csv.Index("Servers");
                csv.Keep(iFirst, iStatus, iSender, iRecipients, iSize, iDirection, iCount, iServers);
                string[] row;
                while ((row = csv.Next()) != null)
                {
                    string direction = row[iDirection] ?? "", status = row[iStatus] ?? "";
                    if (string.IsNullOrEmpty(row[iFirst]) && string.IsNullOrEmpty(row[iStatus])) continue;
                    if (direction == "Incoming (SMTP)" || status == "Rejected (SMTP)" || status == "Deferred (SMTP)" || status == "Not completed (SMTP)") { stats.Refused++; continue; }
                    double size;
                    bool sized = double.TryParse(row[iSize], NumberStyles.Float, Invariant, out size) && size > 0;
                    if ((row[iSender] ?? "").StartsWith(JournalSender, StringComparison.OrdinalIgnoreCase))
                    {
                        stats.Journal++;
                        if (sized) stats.JournalKB += size;
                        continue;
                    }
                    domains.Clear();
                    foreach (string part in (row[iRecipients] ?? "").Split(';'))
                    {
                        string r = part.Trim();
                        if (!r.EndsWith("(Sent)", StringComparison.Ordinal)) continue;
                        int at = r.LastIndexOf('@'), end = r.LastIndexOf(" (", StringComparison.Ordinal);
                        if (at >= 0 && end > at) domains.Add(r.Substring(at + 1, end - at - 1));
                    }
                    string key;
                    if (direction == "Incoming") key = "Inbound";
                    else if (edge)
                    {
                        if (direction == "Originating") key = "Outbound";
                        else { stats.Unknown++; key = "Inbound"; }
                    }
                    else
                    {
                        if (direction != "Originating") stats.Unknown++;
                        key = domains.Count > 0 ? "Outbound" : "Internal";
                    }
                    FlowStats flow = stats.Flows[key];
                    flow.Messages++;
                    if (sized) { flow.SizeSum += size; flow.Sized++; }
                    if (key == "Outbound") flow.Domains += Math.Max(1, domains.Count);
                    double count;
                    if (iCount >= 0 && double.TryParse(row[iCount], NumberStyles.Float, Invariant, out count)) flow.Recipients += count;
                    if (iServers >= 0 && row[iServers] != null)
                        foreach (string server in row[iServers].Split('>')) { string name = server.Trim(); if (name.Length > 0) servers.Add(name); }
                    DateTime when;
                    if (!DateTime.TryParseExact(row[iFirst], "yyyy-MM-dd HH:mm:ss", Invariant, DateTimeStyles.None, out when)) { stats.Undated++; continue; }
                    if (when < stats.First) stats.First = when;
                    if (when > stats.Last) stats.Last = when;
                    Increment(stats.Hours, when.ToString("yyyy-MM-dd HH", Invariant));
                    Increment(stats.Days, when.ToString("yyyy-MM-dd", Invariant) + "|" + key);
                }
            }
            var list = new List<string>(servers);
            list.Sort(StringComparer.OrdinalIgnoreCase);
            stats.Servers = list.ToArray();
            return stats;
        }

        /// <summary>SmtpSessions.csv: receive sessions per role (Edge, Hub, FrontEnd...), TLS sessions, messages accepted.</summary>
        public static RoleSessions[] ReadSessions(string path)
        {
            var roles = new Dictionary<string, Dictionary<string, double[]>>(StringComparer.OrdinalIgnoreCase);
            using (var csv = new CsvRows(path))
            {
                CsvRows.Require(csv, Path.GetFileName(path), "Direction", "Role", "TLS", "Status", "Session ID", "Server");
                int iDirection = csv.Index("Direction"), iRole = csv.Index("Role"), iTls = csv.Index("TLS"), iStatus = csv.Index("Status");
                int iSession = csv.Index("Session ID"), iServer = csv.Index("Server");
                csv.Keep(iDirection, iRole, iTls, iStatus, iSession, iServer);
                string[] row;
                while ((row = csv.Next()) != null)
                {
                    if (row[iDirection] != "Receive") continue;
                    string role = row[iRole] ?? "";
                    Dictionary<string, double[]> sessions;
                    if (!roles.TryGetValue(role, out sessions)) { sessions = new Dictionary<string, double[]>(StringComparer.Ordinal); roles[role] = sessions; }
                    string key = (row[iServer] ?? "") + "|" + (row[iSession] ?? "");
                    double[] entry;
                    if (!sessions.TryGetValue(key, out entry)) { entry = new double[2]; sessions[key] = entry; }
                    string tls = row[iTls];
                    if (!string.IsNullOrEmpty(tls) && tls != "No") entry[0] = 1;
                    if (row[iStatus] == "Accepted") entry[1]++;
                }
            }
            var result = new List<RoleSessions>();
            foreach (var pair in roles)
            {
                var r = new RoleSessions { Role = pair.Key };
                foreach (double[] entry in pair.Value.Values)
                {
                    r.Sessions++;
                    r.TlsSessions += entry[0];
                    r.Accepted += entry[1];
                    if (entry[1] > 0) r.SessionsWithMessages++;
                }
                result.Add(r);
            }
            return result.ToArray();
        }

        static void Increment(Dictionary<string, double> map, string key)
        {
            double value;
            map.TryGetValue(key, out value);
            map[key] = value + 1;
        }
    }
}
