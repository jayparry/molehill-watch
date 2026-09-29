/* Sends the contact form without leaving the page.
   Where it goes:
     - Netlify Forms: nothing to configure. Deploy on Netlify and the form posts to the page itself.
     - Anywhere else: put the endpoint on the form, e.g.
         <form ... data-endpoint="https://formspree.io/f/xxxxxxx">
   If neither is available the form says so and shows the e-mail address instead. */
(function () {
  var EMAIL = 'enquires@molehilldataservices.com';

  document.querySelectorAll('form[data-contact]').forEach(function (form) {
    var note = form.querySelector('.form-note');
    var button = form.querySelector('button[type="submit"]');

    form.addEventListener('submit', function (event) {
      if (!form.reportValidity()) return;                 // let the browser point at the bad field
      if (form.querySelector('[name="bot-field"]').value) { event.preventDefault(); return; }

      var endpoint = form.getAttribute('data-endpoint') || form.getAttribute('action') || '';
      if (!endpoint) return;                               // no handler: fall through to the fallback below

      event.preventDefault();
      form.setAttribute('data-sending', '');
      say('Sending...', '');
      if (button) button.textContent = 'Sending...';

      fetch(endpoint, {
        method: 'POST',
        headers: { 'Accept': 'application/json' },
        body: new URLSearchParams(new FormData(form)).toString(),
      }).then(function (response) {
        if (!response.ok) throw new Error(response.status);
        form.reset();
        say('Thank you - that has arrived. We reply the same working day, usually sooner.', 'ok');
        if (button) button.textContent = 'Sent';
      }).catch(function () {
        say('That did not send. Please e-mail ' + EMAIL + ' and we will pick it up from there.', 'bad');
        if (button) button.textContent = 'Send it';
      }).then(function () {
        form.removeAttribute('data-sending');
      });
    });

    function say(text, kind) {
      if (!note) return;
      note.textContent = text;
      note.className = 'form-note' + (kind ? ' ' + kind : '');
    }
  });
})();
