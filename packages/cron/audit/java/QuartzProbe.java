// Differential oracle: Quartz 2.3.2 org.quartz.CronExpression (6/7-field, Quartz L/W/LW/L-n/#,
// years, exactly one '?' in DOM/DOW, DOW names only in our corpus because Quartz numbers 1=SUN).
// Input lines: opts<TAB>expr<TAB>start_unix<TAB>n. Output: "ERR" | "OK m=<0|1> N <next chain>".
import java.nio.file.*;
import java.util.*;
import org.quartz.CronExpression;

public class QuartzProbe {
  // Same workloads / output as the Pion probe's bench-step / bench-parse.
  static void bench(String mode, String path, int steps, int rounds) throws Exception {
    TimeZone utc = TimeZone.getTimeZone("UTC");
    List<String> exprs = new ArrayList<>();
    for (String line : Files.readAllLines(Paths.get(path))) {
      if (!line.isEmpty()) exprs.add(line.split("\t", -1)[1]);
    }
    Date base = new Date(1704067200L * 1000L);
    long ops = 0, errs = 0, sum = 0, xor = 0;
    if (mode.equals("bench-step")) {
      List<CronExpression> cs = new ArrayList<>();
      for (String e : exprs) { CronExpression c = new CronExpression(e); c.setTimeZone(utc); cs.add(c); }
      for (int r = 0; r < rounds; r++) {
        for (CronExpression c : cs) {
          Date cur = base;
          for (int k = 0; k < steps; k++) {
            Date n = c.getTimeAfter(cur);
            if (n == null) { errs++; break; }
            long ts = n.getTime() / 1000L;
            sum += ts; xor ^= ts; cur = n; ops++;
          }
        }
      }
    } else {
      for (int r = 0; r < rounds; r++) {
        for (String e : exprs) {
          CronExpression c;
          try { c = new CronExpression(e); c.setTimeZone(utc); } catch (Exception ex) { errs++; continue; }
          ops++;
          if (r == rounds - 1) {
            Date n = c.getTimeAfter(base);
            if (n != null) { long ts = n.getTime() / 1000L; sum += ts; xor ^= ts; }
          }
        }
      }
    }
    System.out.print("ops=" + ops + "\nnone_or_err=" + errs + "\nsum=" + sum + "\nxor=" + xor + "\n");
  }

  public static void main(String[] a) throws Exception {
    if (a[0].equals("bench-step")) { bench(a[0], a[1], Integer.parseInt(a[2]), Integer.parseInt(a[3])); return; }
    if (a[0].equals("bench-parse")) { bench(a[0], a[1], 0, Integer.parseInt(a[2])); return; }
    TimeZone utc = TimeZone.getTimeZone("UTC");
    TimeZone.setDefault(utc);
    StringBuilder out = new StringBuilder();
    for (String line : Files.readAllLines(Paths.get(a[0]))) {
      if (line.isEmpty()) continue;
      // Quartz 2.3.2 spins forever on some inputs (e.g. "0 0 0 0W * ?"): 3 s watchdog per case.
      final String[] res = new String[1];
      Thread t = new Thread(() -> res[0] = one(line, utc));
      t.setDaemon(true);
      t.start();
      t.join(3000);
      out.append(res[0] == null ? "HANG" : res[0]).append('\n');
    }
    System.out.print(out);
    System.out.flush();
    System.exit(0);
  }

  static String one(String line, TimeZone utc) {
    StringBuilder out = new StringBuilder();
    {
      String[] f = line.split("\t", -1);
      String expr = f[1].replace("\\t", "\t").replace("\\n", "\n").replace("\\r", "\r");
      CronExpression c;
      try {
        c = new CronExpression(expr);
        c.setTimeZone(utc);
      } catch (Throwable e) {
        return "ERR";
      }
      long ts = Long.parseLong(f[2]);
      int n = Integer.parseInt(f[3]);
      Date cur = new Date(ts * 1000L);
      out.append("OK m=");
      boolean m;
      try { m = c.isSatisfiedBy(cur); } catch (Throwable e) { m = false; }
      out.append(m ? "1" : "0").append(" N");
      for (int i = 0; i < n; i++) {
        Date nx;
        try { nx = c.getTimeAfter(cur); } catch (Throwable e) { nx = null; }
        if (nx == null) { out.append(" -"); break; }
        out.append(' ').append(nx.getTime() / 1000L);
        cur = nx;
      }
    }
    return out.toString();
  }
}
