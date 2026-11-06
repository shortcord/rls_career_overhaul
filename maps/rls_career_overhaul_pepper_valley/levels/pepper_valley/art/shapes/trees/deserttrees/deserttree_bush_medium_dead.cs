
singleton TSShapeConstructor(Deserttree_bush_medium_deadDae)
{
   baseShape = "./deserttree_bush_medium_dead.dae";
   loadLights = "0";
};

function Deserttree_bush_medium_deadDae::onLoad(%this)
{
   %this.addImposter("25", "4", "0", "0", "256", "1", "0");
}
