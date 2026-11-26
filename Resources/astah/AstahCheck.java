import com.change_vision.jude.api.inf.AstahAPI;
import com.change_vision.jude.api.inf.editor.ERModelEditor;
import com.change_vision.jude.api.inf.editor.ITransactionManager;
import com.change_vision.jude.api.inf.model.*;
import com.change_vision.jude.api.inf.presentation.*;
import com.change_vision.jude.api.inf.project.ProjectAccessor;
import java.io.PrintStream;
import java.util.*;

/**
 * Opens an .asta file with Astah itself (through its own API, no window) and writes what Astah found in it:
 * one line per entity, attribute, index, relationship and domain, and per swimlane, node and arrow of each
 * activity diagram, in the form `Schema --export=x.astalist` writes for the diagram the file came from.
 * check.sh compares the two.
 *
 *   AstahCheck <file.asta> <listing.txt> [resaved.asta]
 *
 * It also has Astah validate the file, and with a third argument change it the way a person would (rename an
 * entity, add an attribute, an entity and a relationship) and save it again, to show the file is one Astah can
 * go on working in.
 */
public class AstahCheck {
    static String yes(boolean b) { return b ? "yes" : "no"; }
    static String s(String v) { return v == null ? "" : v; }
    // In the order they were made: the ids count up.
    static final Comparator<INamedElement> byElement = Comparator.comparingLong(e -> Long.parseLong(e.getId().substring(0, e.getId().indexOf('-')), 36));

    /** What a node of an activity diagram is, in the words the export uses. */
    static String kind(IActivityNode n) {
        if (n instanceof IObjectNode) return "object";
        if (n instanceof IControlNode) {
            IControlNode c = (IControlNode) n;
            return c.isInitialNode() ? "initial" : c.isFlowFinalNode() ? "flowFinal" : c.isFinalNode() ? "final" : c.isForkNode() ? "fork" : c.isJoinNode() ? "join"
                : c.isDecisionMergeNode() ? "decision" : c.isConnector() ? "connector" : "control";
        }
        if (n instanceof IAction) {
            IAction x = (IAction) n;
            return x.isSendSignalAction() ? "send" : x.isAcceptEventAction() ? "receive" : x.isAcceptTimeEventAction() ? "timer" : x.isConnector() ? "connector"
                : x.isCallBehaviorAction() ? "call" : x.isProcess() ? "process" : "action";
        }
        return "node";
    }

    public static void main(String[] a) throws Exception {
        ProjectAccessor pa = AstahAPI.getAstahAPI().getProjectAccessor();
        pa.open(a[0], true, false, true);
        PrintStream out = new PrintStream(a[1], "UTF-8");
        IERModel er = null;
        for (INamedElement el : pa.getProject().getOwnedElements()) if (el instanceof IERModel) er = (IERModel) el;
        if (er == null) { System.out.println("FAILED: no ER model in the file"); System.exit(1); }
        IERSchema schema = er.getSchemata()[0];
        List<String> relationships = new ArrayList<>();
        List<String> subtypes = new ArrayList<>();
        for (IEREntity e : schema.getEntities()) {
            out.println("ENTITY " + e.getLogicalName() + "|" + e.getPhysicalName() + "|" + s(e.getDefinition()) + "|" + s(e.getType()) + "|" + s(e.getAlias1()) + "|" + s(e.getAlias2()));
            List<IERAttribute> all = new ArrayList<>(Arrays.asList(e.getPrimaryKeys()));
            all.addAll(Arrays.asList(e.getNonPrimaryKeys()));
            for (IERAttribute at : all) {
                IERAttribute key = at.getReferencedPrimaryKey();
                String source = key == null ? "" : ((INamedElement) key.getOwner()).getName() + "." + key.getName();
                out.println("ATTR " + e.getLogicalName() + "." + at.getLogicalName() + "|" + at.getPhysicalName() + "|pk=" + yes(at.isPrimaryKey()) + "|fk=" + yes(at.isForeignKey())
                    + "|nn=" + yes(at.isNotNull()) + "|" + (at.getDatatype() == null ? "" : at.getDatatype().getName()) + "|" + s(at.getLengthPrecision()) + "|" + s(at.getDefaultValue())
                    + "|" + (at.getDomain() == null ? "" : at.getDomain().getName()) + "|" + source + "|" + s(at.getDefinition()));
            }
            for (IERIndex ix : e.getERIndices()) {
                StringBuilder names = new StringBuilder();
                for (IERAttribute x : ix.getERAttributes()) names.append(names.length() > 0 ? "," : "").append(x.getName());
                out.println("INDEX " + e.getLogicalName() + "|" + ix.getName() + "|" + (ix.isUnique() ? "unique" : "not unique") + "|" + names);
            }
            for (IERRelationship r : e.getChildrenRelationships()) {
                List<String> keys = new ArrayList<>();
                for (IERAttribute x : r.getForeignKeys()) keys.add(x.getName());
                Collections.sort(keys);
                String kind = r.isMultiToMulti() ? "many-to-many" : r.isIdentifying() ? "identifying" : "non-identifying";
                relationships.add(r.getId() + "\t" + "REL " + r.getParent().getName() + ">" + r.getChild().getName() + "|" + r.getLogicalName() + "|" + s(r.getVerbPhraseChild()) + "|" + kind + "|" + r.getCardinality()
                    + "|parentRequired=" + yes(r.isParentRequired()) + "|" + String.join(",", keys) + "|" + (r.getERIndex() == null ? "" : r.getERIndex().getName()) + "|" + s(r.getDefinition()));
            }
            for (IERSubtypeRelationship r : e.getChildrenSubtypeRelationships()) {
                subtypes.add(r.getId() + "\t" + "SUBTYPE " + r.getParent().getName() + ">" + r.getChild().getName() + "|" + r.getLogicalName() + "|complete=" + yes(r.isConclusive())
                    + "|" + (r.getDiscriminatorAttribute() == null ? "" : r.getDiscriminatorAttribute().getName()));
            }
        }
        // In the order they were made: the ids count up.
        Comparator<String> byId = Comparator.comparingLong(l -> Long.parseLong(l.substring(0, l.indexOf('-')), 36));
        relationships.sort(byId);
        subtypes.sort(byId);
        for (String l : relationships) out.println(l.substring(l.indexOf('\t') + 1));
        for (String l : subtypes) out.println(l.substring(l.indexOf('\t') + 1));
        Map<String, String> parents = new HashMap<>();
        List<IERDomain> domains = new ArrayList<>();
        Deque<IERDomain> open = new ArrayDeque<>(Arrays.asList(schema.getDomains()));
        while (!open.isEmpty()) {
            IERDomain d = open.poll();
            domains.add(d);
            for (IERDomain c : d.getChildren()) { parents.put(c.getId(), d.getLogicalName()); open.add(c); }
        }
        domains.sort(Comparator.comparingLong(d -> Long.parseLong(d.getId().substring(0, d.getId().indexOf('-')), 36)));
        for (IERDomain d : domains) {
            out.println("DOMAIN " + d.getLogicalName() + "|" + s(d.getPhysicalName()) + "|" + s(d.getDatatypeName()) + "|" + s(d.getLengthPrecision()) + "|nn=" + yes(d.isNotNull())
                + "|" + s(d.getDefaultValue()) + "|" + s(parents.get(d.getId())) + "|" + s(d.getDefinition()));
        }
        List<INamedElement> diagrams = new ArrayList<>(Arrays.asList(pa.findElements(IERDiagram.class)));
        diagrams.sort(Comparator.comparingLong(d -> Long.parseLong(d.getId().substring(0, d.getId().indexOf('-')), 36)));
        for (INamedElement d : diagrams) {
            IERDiagram dg = (IERDiagram) d;
            int boxes = 0, lines = 0, notes = 0, anchors = 0, texts = 0, shapes = 0;
            for (IPresentation p : dg.getPresentations()) {
                String type = p.getType();
                if (p.getModel() instanceof IEREntity) boxes++;
                else if (p.getModel() instanceof IERRelationship || p.getModel() instanceof IERSubtypeRelationship) lines++;
                else if ("Note".equals(type)) notes++;
                else if ("NoteAnchor".equals(type)) anchors++;
                else if ("Text".equals(type)) texts++;
                else shapes++;
            }
            out.println("DIAGRAM " + dg.getNotation() + "|" + dg.getModelType() + "|boxes=" + boxes + "|lines=" + lines + "|notes=" + notes + "|about=" + anchors + "|texts=" + texts + "|shapes=" + shapes);
        }
        // Activity diagrams: what is on each, which swimlane everything is in, and every arrow with its condition.
        List<INamedElement> flowcharts = new ArrayList<>(Arrays.asList(pa.findElements(IActivityDiagram.class)));
        flowcharts.sort(byElement);
        for (INamedElement d : flowcharts) {
            IActivityDiagram dg = (IActivityDiagram) d;
            IActivity act = dg.getActivity();
            String name = dg.getName();
            int notes = 0, anchors = 0, texts = 0;
            for (IPresentation p : dg.getPresentations()) {
                String type = p.getType();
                if ("Note".equals(type)) notes++;
                else if ("NoteAnchor".equals(type)) anchors++;
                else if ("Text".equals(type)) texts++;
            }
            List<IPartition> lanes = new ArrayList<>();
            for (IPartition top : act.getPartitions()) {
                // The lanes are under the partition that stands for the row of them; left to right.
                IPartition lane = null;
                for (IPartition sub : top.getSubPartitions()) if (sub.getPreviousPartition() == null) lane = sub;
                for (; lane != null; lane = lane.getNextPartition()) lanes.add(lane);
            }
            out.println("ACTIVITY " + name + "|nodes=" + act.getActivityNodes().length + "|flows=" + act.getFlows().length + "|lanes=" + lanes.size()
                + "|notes=" + notes + "|about=" + anchors + "|texts=" + texts);
            for (IPartition lane : lanes) {
                List<String> inside = new ArrayList<>();
                for (IActivityNode n : lane.getActivityNodes()) inside.add(s(n.getName()));
                Collections.sort(inside);
                out.println("LANE " + name + "|" + lane.getName() + "|" + String.join(",", inside));
            }
            List<IActivityNode> nodes = new ArrayList<>(Arrays.asList(act.getActivityNodes()));
            nodes.sort(byElement);
            for (IActivityNode n : nodes) out.println("NODE " + name + "|" + s(n.getName()) + "|" + kind(n) + "|" + s(n.getDefinition()));
            List<IFlow> flows = new ArrayList<>(Arrays.asList(act.getFlows()));
            flows.sort(byElement);
            for (IFlow f : flows) out.println("FLOW " + name + "|" + s(f.getSource().getName()) + ">" + s(f.getTarget().getName()) + "|" + s(f.getGuard()));
        }
        out.close();

        try { pa.validateProject(); System.out.println("ok    Astah's own check finds nothing wrong with the file"); }
        catch (Throwable t) { System.out.println("FAILED: Astah's check: " + t); System.exit(1); }

        if (a.length > 2) {
            ITransactionManager tm = pa.getTransactionManager();
            ERModelEditor me = pa.getModelEditorFactory().getERModelEditor();
            try {
                tm.beginTransaction();
                IEREntity made = me.createEREntity(schema, "Made In Astah", "made_in_astah");
                me.createERAttribute(made, "added in astah", "added_in_astah", schema.getDatatypes()[0]);
                if (schema.getEntities().length > 1) {
                    IEREntity first = schema.getEntities()[0];
                    first.setLogicalName(first.getLogicalName() + " (edited)");
                    if (first.getPrimaryKeys().length > 0) me.createNonIdentifyingRelationship(first, made, "made", "made");
                }
                tm.endTransaction();
                pa.saveAs(a[2]);
                System.out.println("ok    Astah can change the model and save it again");
            } catch (Throwable t) { System.out.println("FAILED: editing in Astah: " + t); System.exit(1); }
        }
        pa.close();
        System.exit(0);
    }
}
