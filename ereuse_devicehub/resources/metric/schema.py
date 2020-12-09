from teal.resource import Schema
from marshmallow.fields import DateTime

class Metric(Schema):
    """
    This schema filter dates for search the metrics
    """
    start_time = DateTime(data_key='start_time', required=True,
                          description="Start date for search metrics")
    end_time = DateTime(data_key='end_time', required=True,
                        description="End date for search metrics")
