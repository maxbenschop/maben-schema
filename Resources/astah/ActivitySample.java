import com.change_vision.jude.api.inf.AstahAPI;
import com.change_vision.jude.api.inf.editor.*;
import com.change_vision.jude.api.inf.model.*;
import com.change_vision.jude.api.inf.presentation.*;
import com.change_vision.jude.api.inf.project.ProjectAccessor;
import java.awt.geom.Point2D;
import java.util.*;

/**
 * Makes an .asta file with an activity diagram through Astah's own API, for make-class-table.py to read the
 * classes from: one of every kind of node, arrows with a guard and an action, swimlanes, a note and text.
 *
 *   ActivitySample <file.asta> [full | plain | small | empty]
 *
 * full: with swimlanes. plain: the same without them. small: three nodes and their arrows. empty: only the diagram.
 * Each step says whether Astah took it, so a new Astah that drops a call shows which.
 */
public class ActivitySample {
    static void attempt(String what, Step s) { try { s.run(); System.out.println("ok   " + what); } catch (Throwable t) { System.out.println("FAIL " + what + ": " + t); } }
    interface Step { void run() throws Exception; }
    static Point2D p(double x, double y) { return new Point2D.Double(x, y); }
    static void show(String what, IPresentation n) {
        if (n instanceof INodePresentation) { INodePresentation q = (INodePresentation) n; System.out.println("     " + what + " type=" + q.getType() + " at " + q.getLocation().getX() + "," + q.getLocation().getY() + " size " + q.getWidth() + "x" + q.getHeight() + " model=" + (q.getModel() == null ? null : q.getModel().getClass().getSimpleName())); }
        else System.out.println("     " + what + " type=" + n.getType());
    }
    public static void main(String[] a) throws Exception {
        ProjectAccessor pa = AstahAPI.getAstahAPI().getProjectAccessor();
        pa.create(a[0]);
        String level = a.length > 1 ? a[1] : "full";
        ITransactionManager tm = pa.getTransactionManager();
        ActivityDiagramEditor d = pa.getDiagramEditorFactory().getActivityDiagramEditor();
        tm.beginTransaction();
        IActivityDiagram dg = d.createActivityDiagram(pa.getProject(), "Order flow");
        d.setDiagram(dg);
        System.out.println("flowchart=" + dg.isFlowChart() + " activity=" + dg.getActivity().getName());
        if (level.equals("empty")) { tm.endTransaction(); pa.save(); pa.close(); System.exit(0); }
        final INodePresentation[] n = new INodePresentation[30];
        final INodePresentation[] lane = new INodePresentation[6];
        if (level.equals("full")) {
            attempt("lane 1", () -> { lane[0] = d.createPartition(null, null, "Customer", false); show("lane", lane[0]); });
            attempt("lane 2", () -> { lane[1] = d.createPartition(null, lane[0], "Shop", false); show("lane", lane[1]); });
            attempt("lane 3", () -> { lane[2] = d.createPartition(null, lane[1], "Warehouse", false); show("lane", lane[2]); });
        }
        attempt("initial", () -> { n[0] = d.createInitialNode("Start", p(100, 80)); show("initial", n[0]); });
        attempt("action", () -> { n[1] = d.createAction("Place order", p(70, 140)); show("action", n[1]); });
        attempt("action 2", () -> { n[2] = d.createAction("Check stock", p(300, 140)); show("action", n[2]); });
        if (level.equals("small")) {
            attempt("flow", () -> { ILinkPresentation f = d.createFlow(n[0], n[1]); show("flow", f); });
            attempt("flow 2", () -> { ILinkPresentation f = d.createFlow(n[1], n[2]); ((IFlow) f.getModel()).setGuard("paid"); });
            attempt("final", () -> { n[3] = d.createFinalNode("Done", p(330, 240)); show("final", n[3]); });
            attempt("flow 3", () -> d.createFlow(n[2], n[3]));
            tm.endTransaction(); pa.save(); pa.close(); System.exit(0);
        }
        attempt("decision", () -> { n[3] = d.createDecisionMergeNode(null, p(330, 230)); show("decision", n[3]); });
        attempt("action 3", () -> { n[4] = d.createAction("Pack parcel", p(540, 220)); show("action", n[4]); });
        attempt("action 4", () -> { n[5] = d.createAction("Tell customer", p(70, 320)); show("action", n[5]); });
        attempt("fork", () -> { n[6] = d.createForkNode(null, p(520, 310), 160, 6); show("fork", n[6]); });
        attempt("action 5", () -> { n[7] = d.createAction("Print label", p(480, 360)); show("action", n[7]); });
        attempt("action 6", () -> { n[8] = d.createAction("Book courier", p(620, 360)); show("action", n[8]); });
        attempt("join", () -> { n[9] = d.createJoinNode(null, p(520, 440), 160, 6); show("join", n[9]); });
        attempt("final", () -> { n[10] = d.createFinalNode("Done", p(590, 500)); show("final", n[10]); });
        attempt("flow final", () -> { n[11] = d.createFlowFinalNode("Stop", p(110, 420)); show("flowfinal", n[11]); });
        attempt("object", () -> { n[12] = d.createObjectNode("Order", null, p(300, 60)); show("object", n[12]); });
        attempt("send", () -> { n[13] = d.createSendSignalAction("Send invoice", p(300, 420)); show("send", n[13]); });
        attempt("accept", () -> { n[14] = d.createAcceptEventAction("Payment received", p(300, 500)); show("accept", n[14]); });
        attempt("time", () -> { n[15] = d.createAcceptTimeEventAction("After 3 days", p(120, 500)); show("time", n[15]); });
        attempt("process", () -> { n[16] = d.createProcess("Refund", p(70, 580)); show("process", n[16]); });
        attempt("connector", () -> { n[17] = d.createConnector("A", p(330, 580)); show("connector", n[17]); });
        attempt("call", () -> { n[18] = d.createCallBehaviorAction("Ship", null, p(540, 580)); show("call", n[18]); });
        attempt("merge", () -> { n[19] = d.createDecisionMergeNode(null, p(240, 320)); show("merge", n[19]); });
        final ILinkPresentation[] f = new ILinkPresentation[30];
        attempt("flow 0-1", () -> { f[0] = d.createFlow(n[0], n[1]); show("flow", f[0]); System.out.println(new TreeMap<Object,Object>(f[0].getProperties())); });
        attempt("flow 1-2", () -> f[1] = d.createFlow(n[1], n[2]));
        attempt("flow 2-3", () -> f[2] = d.createFlow(n[2], n[3]));
        attempt("flow 3-4 guard", () -> { f[3] = d.createFlow(n[3], n[4]); ((IFlow) f[3].getModel()).setGuard("in stock"); });
        attempt("flow 3-5 guard", () -> { f[4] = d.createFlow(n[3], n[19]); ((IFlow) f[4].getModel()).setGuard("sold out"); });
        attempt("flow 19-5", () -> f[11] = d.createFlow(n[19], n[5]));
        attempt("flow 4-6", () -> f[5] = d.createFlow(n[4], n[6]));
        attempt("flow 6-7", () -> f[6] = d.createFlow(n[6], n[7]));
        attempt("flow 6-8", () -> f[7] = d.createFlow(n[6], n[8]));
        attempt("flow 7-9", () -> f[8] = d.createFlow(n[7], n[9]));
        attempt("flow 8-9", () -> f[9] = d.createFlow(n[8], n[9]));
        attempt("flow 9-10", () -> { f[10] = d.createFlow(n[9], n[10]); ((IFlow) f[10].getModel()).setAction("log it"); f[10].getModel(); });
        attempt("flow 5-11", () -> { f[12] = d.createFlow(n[5], n[11]); ((INamedElement) f[12].getModel()).setName("give up"); });
        attempt("flow 12-2 object", () -> f[13] = d.createFlow(n[12], n[2]));
        attempt("flow bent", () -> { f[14] = d.createFlow(n[13], n[14]); f[14].setAllPoints(new Point2D[] { f[14].getAllPoints()[0], p(460, 440), p(460, 520), f[14].getAllPoints()[f[14].getAllPoints().length - 1] }); });
        attempt("definitions", () -> { ((INamedElement) n[1].getModel()).setDefinition("The customer sends the order."); });
        attempt("colour", () -> n[2].setProperty("fill.color", "#CCFFCC"));
        attempt("note", () -> { INodePresentation note = d.createNote("Only on work days", p(640, 100)); d.createNoteAnchor(note, n[4]); });
        attempt("text", () -> d.createText("Order flow", p(20, 20)));
        attempt("node props", () -> { for (int i : new int[] {0, 1, 3, 6, 10, 12}) if (n[i] != null) System.out.println("     " + n[i].getType() + " " + new TreeMap<Object,Object>(n[i].getProperties())); });
        tm.endTransaction();
        pa.save(); pa.close();
        System.exit(0);
    }
}
