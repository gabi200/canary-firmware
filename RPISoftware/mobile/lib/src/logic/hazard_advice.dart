String hazardDont(String hazardType) {
  switch (hazardType) {
    case 'combustible_gas':
      return "Don't use the lift, light switches, or open flames.";
    case 'co':
      return "Don't stay inside. Get to fresh air now.";
    case 'particulate':
      return "Stay low under smoke. Don't use the lift.";
    case 'water_leak':
      return "Don't touch electrical devices or switches near water.";
    default:
      return "Don't use the lift.";
  }
}
