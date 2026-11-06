
singleton TSShapeConstructor(Deserttree_bush_mediumDae)
{
   baseShape = "./deserttree_bush_medium.dae";
   loadLights = "0";
};

function Deserttree_bush_mediumDae::onLoad(%this)
{
   %this.addImposter("25", "4", "0", "0", "256", "1", "0");
}
