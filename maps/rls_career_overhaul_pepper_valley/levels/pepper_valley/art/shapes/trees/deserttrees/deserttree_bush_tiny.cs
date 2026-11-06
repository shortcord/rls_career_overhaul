
singleton TSShapeConstructor(Deserttree_bush_tinyDae)
{
   baseShape = "./deserttree_bush_tiny.dae";
};

function Deserttree_bush_tinyDae::onLoad(%this)
{
   %this.addImposter("25", "4", "0", "0", "256", "1", "0");
}
