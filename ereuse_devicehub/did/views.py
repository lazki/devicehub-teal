import json

import flask
from ereuseapi.methods import API
from flask import Blueprint
from flask import current_app as app
from flask import g, render_template, request, session
from flask.json import jsonify
from flask.views import View

from ereuse_devicehub import __version__
from ereuse_devicehub.resources.device.models import Device
from ereuse_devicehub.resources.did.models import Dpp

did = Blueprint('did', __name__, url_prefix='/did')


class DidView(View):
    methods = ['GET', 'POST']
    template_name = 'did/layout.html'

    def dispatch_request(self, id_dpp):
        self.dpp = None
        self.device = None
        self.get_ids(id_dpp)

        self.context = {
            'version': __version__,
            'oidc': 'oidc' in app.blueprints.keys(),
            'user': g.user,
            'path': request.path,
            'last_dpp': None,
            'before_dpp': None,
            'rols': [],
            'rol': None,
        }
        self.get_rols()
        self.get_rol()
        self.get_device()
        self.get_last_dpp()
        self.get_before_dpp()

        if 'json' in request.headers['Accept']:
            return jsonify(self.get_result())

        return render_template(self.template_name, **self.context)

    def get_ids(self, id_dpp):
        self.id_dpp = None
        self.chid = id_dpp

        if len(id_dpp.split(":")) == 2:
            self.id_dpp = id_dpp
            self.chid = id_dpp.split(':')[0]

    def get_rols(self):
        rols = session.get('rols')
        if not g.user.is_authenticated and not rols:
            return []

        if rols:
            self.context['rols'] = rols

        if 'dpp' not in app.blueprints.keys():
            return []

        if not session.get('token_dlt'):
            return []

        token_dlt = session.get('token_dlt')
        api_dlt = app.config.get('API_DLT')
        if not token_dlt or not api_dlt:
            return []

        api = API(api_dlt, token_dlt, "ethereum")

        result = api.check_user_roles()
        if result.get('Status') != 200:
            return []

        if 'Success' not in result.get('Data', {}).get('status'):
            return []

        rols = result.get('Data', {}).get('data', {})
        self.context['rols'] = [(k, k) for k, v in rols.items() if v]

    def get_rol(self):
        rols = self.context.get('rols', [])
        rol = len(rols) == 1 and rols[0][0] or None
        if 'rol' in request.args and not rol:
            rol = dict(rols).get(request.args.get('rol'))
        self.context['rol'] = rol

    def get_device(self):
        if self.id_dpp:
            self.dpp = Dpp.query.filter_by(key=self.id_dpp).one()
            device = self.dpp.device
        else:
            device = Device.query.filter_by(chid=self.chid, active=True).first()

        if not device:
            return flask.abort(404)

        placeholder = device.binding or device.placeholder
        device_abstract = placeholder and placeholder.binding or device
        device_real = placeholder and placeholder.device or device
        self.device = device_abstract
        components = self.device.components
        if self.dpp:
            components = self.dpp.snapshot.components

        self.context.update(
            {
                'placeholder': placeholder,
                'device': self.device,
                'device_abstract': device_abstract,
                'device_real': device_real,
                'components': components,
            }
        )

    def get_last_dpp(self):
        dpps = sorted(self.device.dpps, key=lambda x: x.created)
        self.context['last_dpp'] = dpps and dpps[-1] or ''
        return self.context['last_dpp']

    def get_before_dpp(self):
        if not self.dpp:
            self.context['before_dpp'] = ''
            return ''

        dpps = sorted(self.device.dpps, key=lambda x: x.created)
        before_dpp = ''
        for dpp in dpps:
            if dpp == self.dpp:
                break
            before_dpp = dpp

        self.context['before_dpp'] = before_dpp
        return before_dpp

    def get_result(self):
        data = {
            'hardware': {},
            'dpp': self.id_dpp,
        }
        result = {'data': data}

        if self.dpp:
            data['hardware'] = json.loads(self.dpp.snapshot.json_hw)
            last_dpp = self.get_last_dpp()
            url_last = ''
            if last_dpp:
                url_last = 'http://did.ereuse.org/{did}'.format(did=last_dpp)
            data['url_last'] = url_last
            return result

        dpps = []
        for d in self.device.dpps:
            rr = {'dpp': d.key, 'hardware': json.loads(d.snapshot.json_hw)}
            dpps.append(rr)
        return {'data': dpps}


did.add_url_rule('/<string:id_dpp>', view_func=DidView.as_view('did'))