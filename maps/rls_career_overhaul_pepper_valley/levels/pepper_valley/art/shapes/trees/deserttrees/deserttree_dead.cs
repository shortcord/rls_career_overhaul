
singleton TSShapeConstructor(Deserttree_deadDae)
{
   baseShape = "./deserttree_dead.dae";
   loadLights = "0";
};

function Deserttree_deadDae::onLoad(%this)
{
   %this.addImposter("25", "4", "0", "0", "256", "1", "0");
}
