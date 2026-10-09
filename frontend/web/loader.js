window.addEventListener('flutter-first-frame', function ()
{
  var indicator = document.getElementById('loading-indicator');
  if (indicator)
  {
    indicator.remove();
  }
});
