import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.sql.Types;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.time.format.ResolverStyle;
import java.time.temporal.ChronoField;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/**
 * Loads "Master Broker Channel List.XLSX" into BROKERMASTER (upsert on CPSCODE).
 * Java 8, no dependencies except the Microsoft SQL Server JDBC driver on the classpath.
 *
 * Exit codes: 0 loaded or nothing to do, 1 failed (nothing committed), 2 loaded but rows were rejected.
 */
public class BrokerMasterLoader {

    // --- Configuration (environment variables) --------------------------------------------
    static final Path SRC_DIR = Paths.get(env("BROKER_SRC_DIR", "/usr/local/mos/brokerinformation"));
    static final String SRC_FILE = env("BROKER_SRC_FILE", "Master Broker Channel List.XLSX");
    static final Path ARCHIVE_DIR = Paths.get(env("BROKER_ARCHIVE_DIR", SRC_DIR.resolve("archive").toString()));
    static final Path STATE_FILE = Paths.get(env("BROKER_STATE_FILE", SRC_DIR.resolve(".last_loaded.sha256").toString()));
    static final Path LOG_DIR = Paths.get(env("BROKER_LOG_DIR", "/var/log/mos"));
    static final String TABLE = env("BROKER_TABLE", "BROKERMASTER");
    // identity | max | SQL expression such as "NEXT VALUE FOR dbo.BROKERMASTER_SEQ"
    static final String ID_MODE = env("BROKER_ID_MODE", "identity").trim();
    static final long MIN_FILE_AGE_SEC = Long.parseLong(env("BROKER_MIN_FILE_AGE_SEC", "120"));

    // Excel header (line breaks / extra spaces ignored, case-insensitive) -> BROKERMASTER column
    static final String[][] COLUMN_MAP = {
        {"CPS Agent or Dealer Code", "CPSCODE"},
        {"MATD Dealer Name or PMPP Dealer Name", "BROKERFIRM"},
        {"PMPP AGENT Name", "AGENT"},
        {"MOS Channel", "BROKERCHANNEL"},
        {"Date added to PMPP or Mortgage Broker Agreement Date", "ADDED"},
        {"Date Removed from PMPP", "REMOVED"},
    };
    // Cell text treated as blank (NULL)
    static final Set<String> NULL_TOKENS = new HashSet<>(Arrays.asList(
        "", "#N/A", "#N/A N/A", "#NA", "<NA>", "N/A", "NA", "n/a", "NULL", "null", "NaN", "nan", "None"));
    static final LocalDate EXCEL_EPOCH = LocalDate.of(1899, 12, 30);
    static final List<DateTimeFormatter> DATE_FORMATS = new ArrayList<>();
    static {
        for (String p : new String[] {"uuuu-M-d", "uuuu/M/d", "M/d/uuuu", "d-MMM-uuuu", "d MMM uuuu",
                                      "MMM d, uuuu", "MMMM d, uuuu", "uuuuMMdd"}) {
            DATE_FORMATS.add(new DateTimeFormatterBuilder().parseCaseInsensitive().appendPattern(p)
                .toFormatter(Locale.ENGLISH).withResolverStyle(ResolverStyle.STRICT));
        }
        // Two-digit years as typed in the file (28-Feb-25). Same rule as Excel: 00-29 -> 2000s, 30-99 -> 1900s
        for (String sep : new String[] {"-", " "}) {
            DATE_FORMATS.add(new DateTimeFormatterBuilder().parseCaseInsensitive().appendPattern("d" + sep + "MMM" + sep)
                .appendValueReduced(ChronoField.YEAR, 2, 2, 1930)
                .toFormatter(Locale.ENGLISH).withResolverStyle(ResolverStyle.STRICT));
        }
    }

    static String env(String name, String dflt) {
        String v = System.getenv(name);
        return v == null || v.isEmpty() ? dflt : v;
    }

    // --- Logging ------------------------------------------------------------------------------
    static BufferedWriter logFile;

    static void log(String level, String msg) {
        String line = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")) + " " + level + " " + msg;
        try {
            if (logFile != null) { logFile.write(line); logFile.newLine(); logFile.flush(); }
        } catch (IOException ignored) { }
        if (!"INFO".equals(level)) System.err.println(line); // cron mails stderr -> only warnings/errors
    }

    // --- Model ----------------------------------------------------------------------------------
    static class Cell {
        final String text; final boolean numeric;
        Cell(String text, boolean numeric) { this.text = text; this.numeric = numeric; }
    }

    static class Row {
        int excelRow; String cps, firm, agent, channel; LocalDate added, removed;
        boolean active() { return added != null && removed == null; }
        List<Object> data() { return Arrays.<Object>asList(firm, agent, channel, added, removed); }
    }

    static class Result {
        final List<Row> rows = new ArrayList<>();
        final List<String[]> exceptions = new ArrayList<>(); // EXCEL_ROW, CPSCODE, ..., REASON
        int rejected;
    }

    // --- XLSX reading (Office Open XML via the JDK, no external libraries) ---------------------
    static Document xml(ZipFile zip, String name) throws Exception {
        ZipEntry e = zip.getEntry(name);
        if (e == null) return null;
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true); // block XXE
        f.setExpandEntityReferences(false);
        DocumentBuilder b = f.newDocumentBuilder();
        try (InputStream in = zip.getInputStream(e)) { return b.parse(in); }
    }

    static List<Element> children(Element parent, String localName) {
        List<Element> out = new ArrayList<>();
        NodeList nl = parent.getElementsByTagNameNS("*", localName);
        for (int i = 0; i < nl.getLength(); i++) out.add((Element) nl.item(i));
        return out;
    }

    /** Concatenated text of all <t> under el, skipping phonetic runs (<rPh>). */
    static String richText(Element el) {
        StringBuilder sb = new StringBuilder();
        for (Element t : children(el, "t")) {
            Node p = t.getParentNode();
            if (p != null && "rPh".equals(p.getLocalName())) continue;
            sb.append(t.getTextContent());
        }
        return sb.toString();
    }

    static int columnIndex(String ref) {
        int col = 0;
        for (char ch : ref.toCharArray()) {
            if (!Character.isLetter(ch)) break;
            col = col * 26 + (Character.toUpperCase(ch) - 'A' + 1);
        }
        return col - 1;
    }

    /** Returns rows of the first worksheet: Excel row number -> (column index -> cell). */
    static TreeMap<Integer, Map<Integer, Cell>> readFirstSheet(Path path) throws Exception {
        try (ZipFile zip = new ZipFile(path.toFile())) {
            Document wb = xml(zip, "xl/workbook.xml");
            if (wb == null) throw new IllegalArgumentException(path.getFileName() + " is not an .xlsx workbook");
            Element sheet = children(wb.getDocumentElement(), "sheet").get(0);
            String rid = sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
            String target = null;
            for (Element rel : children(xml(zip, "xl/_rels/workbook.xml.rels").getDocumentElement(), "Relationship")) {
                if (rel.getAttribute("Id").equals(rid)) target = rel.getAttribute("Target");
            }
            if (target == null) throw new IllegalArgumentException("Cannot locate first worksheet");
            String sheetPath = target.startsWith("/") ? target.substring(1) : "xl/" + target;

            List<String> shared = new ArrayList<>();
            Document ss = xml(zip, "xl/sharedStrings.xml");
            if (ss != null) for (Element si : children(ss.getDocumentElement(), "si")) shared.add(richText(si));

            TreeMap<Integer, Map<Integer, Cell>> rows = new TreeMap<>();
            int lastRow = 0;
            for (Element r : children(xml(zip, sheetPath).getDocumentElement(), "row")) {
                int rowNum = r.hasAttribute("r") ? Integer.parseInt(r.getAttribute("r")) : lastRow + 1;
                lastRow = rowNum;
                Map<Integer, Cell> cells = new HashMap<>();
                int lastCol = -1;
                for (Element c : children(r, "c")) {
                    int col = c.hasAttribute("r") ? columnIndex(c.getAttribute("r")) : lastCol + 1;
                    lastCol = col;
                    String t = c.getAttribute("t");
                    List<Element> vs = children(c, "v");
                    String v = vs.isEmpty() ? null : vs.get(0).getTextContent();
                    Cell cell = null;
                    if ("s".equals(t)) { if (v != null) cell = new Cell(shared.get(Integer.parseInt(v.trim())), false); }
                    else if ("inlineStr".equals(t)) cell = new Cell(richText(c), false);
                    else if ("str".equals(t)) { if (v != null) cell = new Cell(v, false); }
                    else if ("b".equals(t)) { if (v != null) cell = new Cell("1".equals(v) ? "TRUE" : "FALSE", false); }
                    else if ("e".equals(t)) cell = null; // #N/A, #REF! etc. -> blank
                    else if (v != null) cell = new Cell(v, true);
                    if (cell != null) cells.put(col, cell);
                }
                rows.put(rowNum, cells);
            }
            return rows;
        }
    }

    // --- Cleaning ---------------------------------------------------------------------------
    static String normHeader(String h) {
        return h == null ? "" : String.join(" ", h.trim().split("\\s+")).toLowerCase(Locale.ROOT);
    }

    static String plainNumber(String s) {
        return new BigDecimal(s.trim()).stripTrailingZeros().toPlainString(); // 12345.0 -> 12345
    }

    static String textValue(Cell c) {
        if (c == null) return null;
        String s = c.text.trim();
        if (NULL_TOKENS.contains(s)) return null;
        return c.numeric ? plainNumber(s) : s;
    }

    static LocalDate parseDateText(String s) {
        String core = s.trim().replaceAll("(?i)[ T]+\\d{1,2}:\\d{2}(:\\d{2}(\\.\\d+)?)?\\s*(AM|PM)?$", "");
        for (DateTimeFormatter f : DATE_FORMATS) {
            try { return LocalDate.parse(core, f); } catch (Exception ignored) { }
        }
        throw new IllegalArgumentException("not a date: '" + s + "'");
    }

    /** Date, or null when blank; throws IllegalArgumentException when not a date. */
    static LocalDate dateValue(Cell c) {
        if (c == null) return null;
        String s = c.text.trim();
        if (NULL_TOKENS.contains(s)) return null;
        if (c.numeric) { // Excel stores dates as serial day numbers
            double d = Double.parseDouble(s);
            if (d < 1 || d >= 2958466) throw new IllegalArgumentException("not a date: " + s);
            return EXCEL_EPOCH.plusDays((long) Math.floor(d));
        }
        return parseDateText(s);
    }

    static String str(Object o) { return o == null ? "" : o.toString(); }

    /** Cell shown in the exceptions CSV: the date if it parses, otherwise the raw text. */
    static String showDate(Cell c) {
        if (c == null) return "";
        try { return str(dateValue(c)); } catch (IllegalArgumentException e) { return c.text; }
    }

    static Result readFile(Path path) throws Exception {
        TreeMap<Integer, Map<Integer, Cell>> sheet = readFirstSheet(path);
        Integer headerRow = null;
        for (Map.Entry<Integer, Map<Integer, Cell>> e : sheet.entrySet()) {
            if (!e.getValue().isEmpty()) { headerRow = e.getKey(); break; }
        }
        if (headerRow == null) throw new IllegalArgumentException(path.getFileName() + " is empty");

        Map<String, Integer> headers = new HashMap<>();
        Set<String> repeated = new HashSet<>();
        List<String> found = new ArrayList<>();
        for (Map.Entry<Integer, Cell> e : new TreeMap<>(sheet.get(headerRow)).entrySet()) {
            found.add(e.getValue().text);
            if (headers.putIfAbsent(normHeader(e.getValue().text), e.getKey()) != null) repeated.add(normHeader(e.getValue().text));
        }
        for (String[] m : COLUMN_MAP) { // e.g. a hidden column with the same heading: don't guess which one to load
            if (repeated.contains(normHeader(m[0]))) {
                throw new IllegalArgumentException("Column '" + m[0] + "' appears more than once in " + path.getFileName()
                    + " (check hidden columns)");
            }
        }
        int[] col = new int[COLUMN_MAP.length];
        List<String> missing = new ArrayList<>();
        for (int i = 0; i < COLUMN_MAP.length; i++) {
            Integer idx = headers.get(normHeader(COLUMN_MAP[i][0]));
            if (idx == null) missing.add(COLUMN_MAP[i][0]); else col[i] = idx;
        }
        if (!missing.isEmpty()) {
            throw new IllegalArgumentException("Missing column(s) in " + path.getFileName() + ": " + missing + ". Found: " + found);
        }

        Result res = new Result();
        List<Row> valid = new ArrayList<>();
        for (Map.Entry<Integer, Map<Integer, Cell>> e : sheet.tailMap(headerRow, false).entrySet()) {
            Map<Integer, Cell> cells = e.getValue();
            Cell[] c = new Cell[COLUMN_MAP.length];
            boolean blank = true;
            for (int i = 0; i < c.length; i++) {
                c[i] = cells.get(col[i]);
                if (textValue(c[i]) != null) blank = false;
            }
            if (blank) continue;

            Row r = new Row();
            r.excelRow = e.getKey();
            r.cps = textValue(c[0]); r.firm = textValue(c[1]); r.agent = textValue(c[2]); r.channel = textValue(c[3]);
            String reason = null;
            try { r.added = dateValue(c[4]); } catch (IllegalArgumentException ex) { reason = "Invalid ADDED date: '" + c[4].text + "'"; }
            if (reason == null) {
                try { r.removed = dateValue(c[5]); } catch (IllegalArgumentException ex) { reason = "Invalid REMOVED date: '" + c[5].text + "'"; }
            }
            if (reason == null && r.cps == null) reason = "Missing CPS Agent or Dealer Code";
            if (reason != null) {
                res.exceptions.add(new String[] {String.valueOf(r.excelRow), str(r.cps), str(r.firm), str(r.agent), str(r.channel),
                    showDate(c[4]), showDate(c[5]), reason});
                res.rejected++;
                continue;
            }
            valid.add(r);
        }

        // Duplicate CPSCODE: keep ADDED populated + REMOVED empty first, then latest ADDED, then first in file
        Comparator<Row> priority = Comparator.<Row, Boolean>comparing(Row::active).reversed()
            .thenComparing(x -> x.added, Comparator.nullsLast(Comparator.<LocalDate>reverseOrder()))
            .thenComparingInt(x -> x.excelRow);
        Map<String, List<Row>> byCode = new LinkedHashMap<>();
        for (Row r : valid) byCode.computeIfAbsent(r.cps, k -> new ArrayList<>()).add(r);
        for (List<Row> group : byCode.values()) {
            group.sort(priority);
            Row kept = group.get(0);
            res.rows.add(kept);
            for (Row d : group.subList(1, group.size())) {
                res.exceptions.add(new String[] {String.valueOf(d.excelRow), d.cps, str(d.firm), str(d.agent), str(d.channel),
                    str(d.added), str(d.removed), "Duplicate CPSCODE; kept Excel row " + kept.excelRow});
            }
        }
        res.rows.sort(Comparator.comparingInt(x -> x.excelRow));
        return res;
    }

    // --- Database ---------------------------------------------------------------------------
    static Object dbText(Object o) {
        if (o == null) return null;
        if (o instanceof Number) return plainNumber(o.toString());
        String s = o.toString().trim();
        return s.isEmpty() ? null : s;
    }

    static Object dbDate(Object o) {
        if (o == null) return null;
        if (o instanceof java.sql.Timestamp) return ((java.sql.Timestamp) o).toLocalDateTime().toLocalDate();
        if (o instanceof java.sql.Date) return ((java.sql.Date) o).toLocalDate();
        if (o instanceof LocalDate) return o;
        if (o instanceof LocalDateTime) return ((LocalDateTime) o).toLocalDate();
        String s = o.toString().trim();
        if (s.isEmpty()) return null;
        try { return parseDateText(s); } catch (IllegalArgumentException e) { return s; } // differs -> gets updated
    }

    /** Blank text is written as '' (not NULL), matching the existing BROKERMASTER data. */
    static void setText(PreparedStatement ps, int i, String v) throws Exception {
        ps.setString(i, v == null ? "" : v);
    }

    static void setDate(PreparedStatement ps, int i, LocalDate v) throws Exception {
        if (v == null) ps.setNull(i, Types.DATE); else ps.setDate(i, java.sql.Date.valueOf(v));
    }

    static Map<String, Integer> upsert(Connection conn, List<Row> rows) throws Exception {
        Map<String, List<Object>> existing = new HashMap<>();
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery("SELECT CPSCODE, BROKERFIRM, AGENT, BROKERCHANNEL, ADDED, REMOVED FROM " + TABLE)) {
            while (rs.next()) {
                String code = (String) dbText(rs.getObject(1));
                if (existing.containsKey(code)) {
                    throw new IllegalStateException(TABLE + " already has duplicate CPSCODE '" + code + "'; clean it up before loading");
                }
                existing.put(code, Arrays.asList(dbText(rs.getObject(2)), dbText(rs.getObject(3)), dbText(rs.getObject(4)),
                                                 dbDate(rs.getObject(5)), dbDate(rs.getObject(6))));
            }
        }

        List<Row> inserts = new ArrayList<>(), updates = new ArrayList<>();
        int unchanged = 0;
        Set<String> inFile = new HashSet<>();
        for (Row r : rows) {
            inFile.add(r.cps);
            List<Object> cur = existing.get(r.cps);
            if (!existing.containsKey(r.cps)) inserts.add(r);
            else if (!Objects.equals(cur, r.data())) updates.add(r);
            else unchanged++;
        }

        if (!updates.isEmpty()) {
            try (PreparedStatement ps = conn.prepareStatement("UPDATE " + TABLE
                    + " SET BROKERFIRM = ?, AGENT = ?, BROKERCHANNEL = ?, ADDED = ?, REMOVED = ? WHERE CPSCODE = ?")) {
                for (Row r : updates) {
                    setText(ps, 1, r.firm); setText(ps, 2, r.agent); setText(ps, 3, r.channel);
                    setDate(ps, 4, r.added); setDate(ps, 5, r.removed); setText(ps, 6, r.cps);
                    ps.addBatch();
                }
                ps.executeBatch();
            }
        }

        if (!inserts.isEmpty()) {
            String cols = "CPSCODE, BROKERFIRM, AGENT, BROKERCHANNEL, ADDED, REMOVED";
            String sql;
            long nextId = 0;
            boolean bindId = false;
            if (ID_MODE.equalsIgnoreCase("identity")) {
                sql = "INSERT INTO " + TABLE + " (" + cols + ") VALUES (?, ?, ?, ?, ?, ?)";
            } else if (ID_MODE.equalsIgnoreCase("max")) {
                try (Statement st = conn.createStatement();
                     ResultSet rs = st.executeQuery("SELECT COALESCE(MAX(ID), 0) FROM " + TABLE)) {
                    rs.next();
                    nextId = rs.getLong(1) + 1;
                }
                bindId = true;
                sql = "INSERT INTO " + TABLE + " (ID, " + cols + ") VALUES (?, ?, ?, ?, ?, ?, ?)";
            } else if (ID_MODE.matches("[\\w.$# ]+")) {
                sql = "INSERT INTO " + TABLE + " (ID, " + cols + ") VALUES (" + ID_MODE + ", ?, ?, ?, ?, ?, ?)";
            } else {
                throw new IllegalArgumentException("Invalid BROKER_ID_MODE: '" + ID_MODE + "'");
            }
            try (PreparedStatement ps = conn.prepareStatement(sql)) {
                for (Row r : inserts) {
                    int i = 1;
                    if (bindId) ps.setLong(i++, nextId++);
                    setText(ps, i++, r.cps); setText(ps, i++, r.firm); setText(ps, i++, r.agent);
                    setText(ps, i++, r.channel); setDate(ps, i++, r.added); setDate(ps, i, r.removed);
                    ps.addBatch();
                }
                ps.executeBatch();
            }
        }

        Set<String> notInFile = new HashSet<>(existing.keySet());
        notInFile.removeAll(inFile);
        Map<String, Integer> stats = new LinkedHashMap<>();
        stats.put("inserted", inserts.size());
        stats.put("updated", updates.size());
        stats.put("unchanged", unchanged);
        stats.put("in_db_not_in_file", notInFile.size());
        return stats;
    }

    // --- Main -------------------------------------------------------------------------------
    static String sha256(Path p) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        StringBuilder sb = new StringBuilder();
        for (byte b : md.digest(Files.readAllBytes(p))) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    static String csv(String v) { return "\"" + (v == null ? "" : v.replace("\"", "\"\"")) + "\""; }

    static void usage(PrintStream out) {
        out.println("Usage: BrokerMasterLoader [--file PATH] [--force] [--dry-run]");
        out.println("  --file PATH  Excel file to load (default: $BROKER_SRC_DIR/$BROKER_SRC_FILE)");
        out.println("  --force      load even if the file has not changed since the last load");
        out.println("  --dry-run    validate and report, then roll back");
        out.println("Environment: DB_URL (JDBC URL), DB_USER, DB_PASSWORD, BROKER_* overrides (see .env.example)");
    }

    public static void main(String[] args) {
        System.exit(run(args));
    }

    static int run(String[] args) {
        Path file = SRC_DIR.resolve(SRC_FILE);
        boolean force = false, dryRun = false;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--file": file = Paths.get(args[++i]); break;
                case "--force": force = true; break;
                case "--dry-run": dryRun = true; break;
                case "-h": case "--help": usage(System.out); return 0;
                default: usage(System.err); return 1;
            }
        }

        try {
            Files.createDirectories(LOG_DIR);
            logFile = Files.newBufferedWriter(LOG_DIR.resolve("brokermaster_load.log"), StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (IOException e) {
            System.err.println("Cannot open log in " + LOG_DIR + ": " + e);
            return 1;
        }

        String stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"));
        Result res;
        String fileHash;
        try {
            if (!Files.exists(file)) { log("INFO", "No file at " + file + "; nothing to do"); return 0; }
            long ageSec = (System.currentTimeMillis() - Files.getLastModifiedTime(file).toMillis()) / 1000;
            if (ageSec < MIN_FILE_AGE_SEC) {
                log("INFO", file.getFileName() + " modified < " + MIN_FILE_AGE_SEC + "s ago; may still be copying, will retry next run");
                return 0;
            }
            fileHash = sha256(file);
            if (!force && Files.exists(STATE_FILE)
                    && new String(Files.readAllBytes(STATE_FILE), StandardCharsets.UTF_8).trim().equals(fileHash)) {
                log("INFO", file.getFileName() + " unchanged since last load; nothing to do");
                return 0;
            }

            res = readFile(file);
            log("INFO", "Read " + file.getFileName() + ": " + res.rows.size() + " unique CPSCODE rows, "
                + res.exceptions.size() + " exceptions");
            if (res.rows.isEmpty()) throw new IllegalArgumentException("No valid rows in file; refusing to load");

            String url = System.getenv("DB_URL");
            if (url == null || url.isEmpty()) throw new IllegalStateException("DB_URL is not set (see .env.example)");
            String user = System.getenv("DB_USER");
            try (Connection conn = user == null || user.isEmpty()
                    ? DriverManager.getConnection(url)
                    : DriverManager.getConnection(url, user, System.getenv("DB_PASSWORD"))) {
                conn.setAutoCommit(false);
                try {
                    Map<String, Integer> stats = upsert(conn, res.rows);
                    if (dryRun) conn.rollback(); else conn.commit();
                    log("INFO", (dryRun ? "DRY RUN (rolled back) " : "") + TABLE + ": " + stats);
                    if (stats.get("in_db_not_in_file") > 0) {
                        log("INFO", stats.get("in_db_not_in_file") + " CPSCODE(s) in " + TABLE + " are not in the file; left unchanged");
                    }
                } catch (Exception e) {
                    conn.rollback();
                    throw e;
                }
            }
        } catch (Exception e) {
            log("ERROR", "Load of " + file + " FAILED; nothing committed: " + e);
            for (StackTraceElement el : e.getStackTrace()) log("DEBUG", "    at " + el);
            return 1;
        }

        try {
            if (!res.exceptions.isEmpty()) {
                Path out = LOG_DIR.resolve("brokermaster_exceptions_" + stamp + ".csv");
                List<String> lines = new ArrayList<>();
                lines.add("EXCEL_ROW,CPSCODE,BROKERFIRM,AGENT,BROKERCHANNEL,ADDED,REMOVED,REASON");
                for (String[] x : res.exceptions) {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < x.length; i++) sb.append(i == 0 ? "" : ",").append(csv(x[i]));
                    lines.add(sb.toString());
                }
                Files.write(out, lines, StandardCharsets.UTF_8);
                log("WARNING", res.exceptions.size() + " row(s) rejected or de-duplicated; details in " + out);
            }
            if (!dryRun) {
                Files.createDirectories(ARCHIVE_DIR);
                String name = file.getFileName().toString();
                int dot = name.lastIndexOf('.');
                String archived = dot < 0 ? name + "_" + stamp : name.substring(0, dot) + "_" + stamp + name.substring(dot);
                Files.copy(file, ARCHIVE_DIR.resolve(archived), StandardCopyOption.COPY_ATTRIBUTES, StandardCopyOption.REPLACE_EXISTING);
                Files.write(STATE_FILE, fileHash.getBytes(StandardCharsets.UTF_8));
            }
        } catch (IOException e) {
            log("WARNING", "Data committed, but post-load housekeeping failed: " + e);
        }
        return res.rejected > 0 ? 2 : 0;
    }
}
