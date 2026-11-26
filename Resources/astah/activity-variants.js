// For check.sh: changes the sample's activity diagram into the cases the plain sample doesn't have, and adds a
// second activity diagram without swimlanes. Run with `Schema --features --script=activity-variants.js`.
var first = diagram.activities[0];
first.nodes.forEach(function (n) {
    // A node with a size and colours of its own, and a name of two lines.
    if (n.name === 'Pack parcel') {
        n.name = 'Pack the\nparcel';
        n.width = 160;
        n.height = 50;
        n.style = { fill: '#FFCC99', line: '#CC0000', text: '#003399' };
    }
    // A bar that stands up.
    if (n.kind === 'fork') { n.width = 6; n.height = 90; }
    if (n.kind === 'decision') { n.name = 'In stock?'; }
});
first.flows[0].style = { line: '#CC0000' };

// The same again as a second diagram: no swimlanes, a name with signs in it, and a bent line from the note.
var second = JSON.parse(JSON.stringify(first));
second.id = '00000000-0000-0000-0000-0000000000AB';
second.name = 'Flow "2" <&> é';
second.lanes = [];
second.flows.forEach(function (f) {
    var from = second.nodes.filter(function (n) { return n.id === f.from; })[0];
    if (from && from.kind === 'note') { f.waypoints = [{ x: 720, y: 240 }]; }
});
diagram.activities.push(second);
log(diagram.activities.length + ' activity diagrams');
